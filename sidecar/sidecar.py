from __future__ import annotations

import argparse
import base64
import json
import queue
import sys
import threading
import time
from pathlib import Path
from typing import Iterable

import numpy as np

DEFAULT_MODEL = "mlx-community/nemotron-3.5-asr-streaming-0.6b"
LOW_MEMORY_MODEL = "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
VALID_ATT_CONTEXTS = {(56, 0), (56, 3), (56, 6), (56, 13)}
_emit_lock = threading.Lock()


def emit(message: dict) -> None:
    with _emit_lock:
        print(json.dumps(message, ensure_ascii=False), flush=True)


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


class NemotronStreamingSession:
    def __init__(self, model, *, language: str | None = "auto", chunk_frames: int | None = None):
        import mlx.core as mx

        self.mx = mx
        self.model = model
        self.language = language or model.default_language
        self.dtype = mx.float32

        self.pre = model.preprocessor_config
        self.enc = model.encoder
        self.att_context_size = model.default_att_context_size
        self.left_cache = int(self.att_context_size[0])
        right_context = int(self.att_context_size[1])
        self.chunk_frames = chunk_frames or (right_context + 1)
        self.subsampling_factor = self.enc.args.subsampling_factor
        self.chunk_mel_frames = self.chunk_frames * self.subsampling_factor
        self.conv_left = self.enc.args.conv_kernel_size - 1

        layer_count = len(self.enc.layers)
        self.attn_cache = [None] * layer_count
        self.conv_cache = [None] * layer_count
        self.pre_encode_mel_cache = None
        self.pending_mel = None
        self.consumed_mel_frames = 0
        self.emitted_encoder_frames = 0
        self.ready_mel_frames = 0

        self.audio = mx.zeros((0,), dtype=self.dtype)
        self.last_token = model.blank_id
        self.decoder_hidden = None
        self.hypothesis = []
        self.global_encoder_time = 0
        self.frame_sec = (
            model.encoder_config.subsampling_factor
            * model.preprocessor_config.hop_length
            / model.preprocessor_config.sample_rate
        )

    @property
    def sample_rate(self) -> int:
        return int(self.pre.sample_rate)

    def feed_audio(self, samples, *, final: bool = False):
        from mlx_audio.stt.models.nemotron_asr.audio import log_mel_spectrogram

        mx = self.mx
        chunk = self._as_mx_audio(samples)
        if chunk.shape[0] > 0:
            self.audio = mx.concatenate([self.audio, chunk])

        if self.audio.shape[0] == 0:
            return []

        mel = log_mel_spectrogram(self.audio, self.pre)
        ready = self._ready_mel_count(mel.shape[1], final=final)
        if ready <= self.ready_mel_frames:
            return []

        mel_delta = mel[:, self.ready_mel_frames:ready]
        self.ready_mel_frames = ready
        return self.feed_mel(mel_delta, final=final)

    def finish(self):
        return self.feed_audio(self.mx.zeros((0,), dtype=self.dtype), final=True)

    def feed_mel(self, mel, *, final: bool = False):
        mx = self.mx
        if mel.ndim == 2:
            mel = mx.expand_dims(mel, 0)

        if mel.shape[1] > 0:
            self.pending_mel = mel if self.pending_mel is None else mx.concatenate([self.pending_mel, mel], axis=1)

        updates = []
        while self.pending_mel is not None and self.pending_mel.shape[1] > 0:
            pending_len = self.pending_mel.shape[1]
            if pending_len < self.chunk_mel_frames and not final:
                break

            take = pending_len if final else self.chunk_mel_frames
            current = self.pending_mel[:, :take]
            remaining = self.pending_mel[:, take:]
            self.pending_mel = remaining if remaining.shape[1] else None

            prompted = self._encode_mel_chunk(current, final=final and self.pending_mel is None)
            if prompted is not None:
                updates.append(self._decode_prompted(prompted))

        if final:
            mx.clear_cache()
        return updates

    def _as_mx_audio(self, samples):
        mx = self.mx
        if isinstance(samples, mx.array):
            audio = samples
        else:
            audio = mx.array(np.asarray(samples, dtype=np.float32))

        if audio.ndim > 1:
            audio = mx.mean(audio, axis=-1)
        if audio.dtype != self.dtype:
            audio = audio.astype(self.dtype)
        return audio.reshape((-1,))

    def _ready_mel_count(self, total_mel_frames: int, *, final: bool) -> int:
        if final:
            return total_mel_frames
        safe_samples = self.audio.shape[0] - (self.pre.n_fft // 2)
        if safe_samples < 0:
            return 0
        safe_frames = safe_samples // self.pre.hop_length + 1
        return min(int(safe_frames), total_mel_frames)

    def _encode_mel_chunk(self, mel_chunk, *, final: bool):
        from mlx_audio.stt.models.nemotron_asr.streaming import _PRE_ENCODE_MEL_CACHE, _stream_block

        mx = self.mx
        cache_len = 0 if self.pre_encode_mel_cache is None else self.pre_encode_mel_cache.shape[1]
        win = mel_chunk if self.pre_encode_mel_cache is None else mx.concatenate([self.pre_encode_mel_cache, mel_chunk], axis=1)
        win_len = win.shape[1]
        sub = self.enc.pre_encode(win, mx.array([win_len], dtype=mx.int32))[0]

        end = self.consumed_mel_frames + mel_chunk.shape[1]
        base = (self.consumed_mel_frames - cache_len) // self.subsampling_factor
        lo = self.emitted_encoder_frames - base
        hi = sub.shape[1] if final else (end // self.subsampling_factor - base)

        self.consumed_mel_frames = end
        self.pre_encode_mel_cache = win[:, -_PRE_ENCODE_MEL_CACHE:]

        if hi <= lo:
            self.emitted_encoder_frames = base + max(lo, hi)
            return None

        self.emitted_encoder_frames = base + hi
        h = sub[:, lo:hi]
        for layer_index, block in enumerate(self.enc.layers):
            h, self.attn_cache[layer_index], self.conv_cache[layer_index] = _stream_block(
                block,
                h,
                self.enc.pos_enc,
                self.attn_cache[layer_index],
                self.conv_cache[layer_index],
                self.left_cache,
                self.conv_left,
            )
        return self.model.apply_prompt(h, self.language)

    def _decode_prompted(self, prompted):
        import mlx.core as mx
        from mlx_audio.stt.models.nemo.alignment import AlignedToken, sentences_to_result, tokens_to_sentences
        from mlx_audio.stt.models.nemotron_asr import tokenizer as tok

        chunk_len = prompted.shape[1]
        time_index = 0
        new_symbols = 0

        while time_index < chunk_len:
            feature = prompted[:, time_index:time_index + 1]
            current_token = mx.array([[self.last_token]], dtype=mx.int32) if self.last_token != self.model.blank_id else None
            decoder_output, (h, c) = self.model.decoder(current_token, self.decoder_hidden)
            decoder_output = decoder_output.astype(feature.dtype)
            proposed_hidden = (h.astype(feature.dtype), c.astype(feature.dtype))
            joint_output = self.model.joint(feature, decoder_output)
            pred_token = int(mx.argmax(joint_output))

            if pred_token != self.model.blank_id:
                self.last_token = pred_token
                self.decoder_hidden = proposed_hidden
                if not tok.is_special_token(pred_token, self.model.vocabulary):
                    self.hypothesis.append(
                        AlignedToken(
                            pred_token,
                            start=(self.global_encoder_time + time_index) * self.frame_sec,
                            duration=self.frame_sec,
                            text=tok.decode([pred_token], self.model.vocabulary),
                        )
                    )
                new_symbols += 1
                if self.model.max_symbols is not None and new_symbols >= self.model.max_symbols:
                    time_index += 1
                    new_symbols = 0
            else:
                time_index += 1
                new_symbols = 0

        self.global_encoder_time += chunk_len
        return sentences_to_result(tokens_to_sentences(self.hypothesis))


class NemotronSidecar:
    def __init__(self, *, model_id: str, low_memory: bool, language: str, chunk_seconds: float):
        self.model_id = LOW_MEMORY_MODEL if low_memory else model_id
        self.language = language
        self.chunk_seconds = chunk_seconds
        self.model = None
        self.streams = {}
        self.cancelled_streams = set()
        self.stream_lock = threading.Lock()

    def ensure_model(self):
        if self.model is not None:
            return
        from mlx_audio.stt import load

        emit({"type": "status", "state": "loading", "model": self.model_id})
        log(f"Loading {self.model_id}...")
        self.model = load(self.model_id)
        emit({"type": "status", "state": "ready", "model": self.model_id})

    def transcribe(self, audio_path: Path, *, request_id: str | None = None) -> None:
        from mlx_audio.stt.utils import load_audio

        if not audio_path.exists():
            raise FileNotFoundError(f"audio file not found: {audio_path}")

        self.ensure_model()
        session = NemotronStreamingSession(self.model, language=self.language)
        audio = load_audio(audio_path, session.sample_rate)
        chunk_samples = max(1, int(session.sample_rate * self.chunk_seconds))
        previous_text = ""
        started = time.monotonic()

        emit({"type": "started", "request_id": request_id, "audio_path": str(audio_path)})
        for start in range(0, audio.shape[0], chunk_samples):
            chunk = audio[start:start + chunk_samples]
            previous_text = self._emit_updates(session.feed_audio(chunk), previous_text, request_id=request_id)

        previous_text = self._emit_updates(session.finish(), previous_text, request_id=request_id)
        elapsed = time.monotonic() - started
        emit({"type": "done", "request_id": request_id, "text": previous_text.strip(), "elapsed": elapsed})

    def start_stream(self, *, request_id: str) -> None:
        self.ensure_model()
        stream = {
            "session": NemotronStreamingSession(self.model, language=self.language),
            "previous_text": "",
            "started": time.monotonic(),
        }
        with self.stream_lock:
            if request_id in self.cancelled_streams:
                return
            self.streams[request_id] = stream
            emit({"type": "started", "request_id": request_id})

    def feed_stream(self, samples: np.ndarray, *, request_id: str) -> None:
        with self.stream_lock:
            if request_id in self.cancelled_streams:
                return
            stream = self.streams.get(request_id)
        if stream is None:
            raise RuntimeError(f"stream not found: {request_id}")

        session = stream["session"]
        previous_text = stream["previous_text"]
        stream["previous_text"] = self._emit_updates(
            session.feed_audio(samples),
            previous_text,
            request_id=request_id,
        )

    def finish_stream(self, *, request_id: str) -> None:
        with self.stream_lock:
            if request_id in self.cancelled_streams:
                return
            stream = self.streams.pop(request_id, None)
        if stream is None:
            raise RuntimeError(f"stream not found: {request_id}")

        session = stream["session"]
        previous_text = stream["previous_text"]
        final_text = self._emit_updates(session.finish(), previous_text, request_id=request_id)
        elapsed = time.monotonic() - stream["started"]
        with self.stream_lock:
            if request_id not in self.cancelled_streams:
                emit({"type": "done", "request_id": request_id, "text": final_text.strip(), "elapsed": elapsed})

    def cancel_stream(self, *, request_id: str) -> None:
        with self.stream_lock:
            self.streams.pop(request_id, None)
            self.cancelled_streams.add(request_id)

    def _emit_updates(self, updates, previous_text: str, *, request_id: str | None) -> str:
        for result in updates:
            current_text = result.text
            if current_text.startswith(previous_text):
                delta = current_text[len(previous_text):]
            else:
                delta = current_text
            if delta:
                with self.stream_lock:
                    if request_id in self.cancelled_streams:
                        return previous_text
                    emit({"type": "chunk", "request_id": request_id, "text": delta, "transcript": current_text})
            previous_text = current_text
        return previous_text


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Magic Voice Nemotron JSONLines sidecar")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--low-memory", action="store_true")
    parser.add_argument("--language", default="auto")
    parser.add_argument("--audio-chunk-seconds", type=float, default=0.5)
    parser.add_argument("--download-model", action="store_true")
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv)
    sidecar = NemotronSidecar(
        model_id=args.model,
        low_memory=args.low_memory,
        language=args.language,
        chunk_seconds=args.audio_chunk_seconds,
    )

    if args.download_model:
        sidecar.ensure_model()
        emit({"type": "status", "state": "downloaded", "model": sidecar.model_id})
        return 0

    emit({"type": "status", "state": "booted", "model": sidecar.model_id})

    messages: queue.Queue[dict | None] = queue.Queue()

    def read_messages() -> None:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
                if message.get("type") == "cancel_stream":
                    sidecar.cancel_stream(request_id=message["request_id"])
                else:
                    messages.put(message)
            except Exception as exc:
                emit({"type": "error", "message": str(exc)})
        messages.put(None)

    threading.Thread(target=read_messages, name="sidecar-stdin", daemon=True).start()

    while True:
        message = messages.get()
        if message is None:
            return 0
        try:
            message_type = message.get("type")
            if message_type == "ping":
                emit({"type": "pong"})
            elif message_type == "transcribe":
                sidecar.transcribe(Path(message["audio_path"]), request_id=message.get("request_id"))
            elif message_type == "start_stream":
                sidecar.start_stream(request_id=message["request_id"])
            elif message_type == "audio_chunk":
                payload = base64.b64decode(message["data"])
                samples = np.frombuffer(payload, dtype="<f4").copy()
                sidecar.feed_stream(samples, request_id=message["request_id"])
            elif message_type == "finish_stream":
                sidecar.finish_stream(request_id=message["request_id"])
            elif message_type == "shutdown":
                emit({"type": "status", "state": "shutdown"})
                return 0
            else:
                emit({"type": "error", "message": f"unknown message type: {message_type}"})
        except Exception as exc:
            emit({"type": "error", "message": str(exc)})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
