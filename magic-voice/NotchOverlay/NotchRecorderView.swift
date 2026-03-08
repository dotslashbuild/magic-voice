//
//  NotchRecorderView.swift
//  magic-voice
//
//  Magic Voice — SwiftUI content rendered inside the floating recorder panel.
//

import SwiftUI

struct NotchRecorderView: View {
    @EnvironmentObject private var manager: NotchWindowManager

    private let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.80)
    private let collapseAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)

    var body: some View {
        VStack(spacing: 6) {
            overlayContent
                .frame(width: notchWidth, height: notchHeight)
                .opacity(manager.state == .collapsed ? 0 : 1)
                .scaleEffect(manager.state == .collapsed ? 0.96 : 1.0, anchor: .top)
                .animation(animation, value: manager.state)

            transcriptLayer
                .opacity(showsTranscript ? 1 : 0)
                .scaleEffect(showsTranscript ? 1.0 : 0.98, anchor: .top)
                .animation(animation, value: manager.state)
                .animation(.easeInOut(duration: 0.16), value: manager.liveTranscript)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private var overlayContent: some View {
        ZStack {
            NotchShape(topCornerRadius: 8, bottomCornerRadius: 15)
                .fill(.black.opacity(0.92))
                .shadow(color: .black.opacity(0.28), radius: 20, y: 10)

            controlsRow
                .padding(.horizontal, 12)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var controlsRow: some View {
        if manager.hasHardwareNotch {
            HStack(spacing: 0) {
                visibleWing {
                    recordingDot
                }

                Spacer(minLength: 0)
                    .frame(width: manager.notchBaseWidth)

                visibleWing {
                    waveform
                    if manager.state == .finished {
                        finishedIcon
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                recordingDot
                waveform
                if manager.state == .finished {
                    finishedIcon
                }
            }
        }
    }

    private var transcriptLayer: some View {
        Text(transcriptText)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.94))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(width: transcriptWidth, alignment: .center)
            .background {
                Capsule()
                    .fill(.black.opacity(0.82))
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
            }
            .accessibilityHidden(true)
    }

    private func visibleWing<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .frame(width: visibleWingWidth, height: 18)
    }

    private var recordingDot: some View {
        Circle()
            .fill(manager.state == .finished ? Color.green : Color.red)
            .frame(width: 7, height: 7)
            .shadow(color: manager.state == .finished ? .green.opacity(0.7) : .red.opacity(0.7), radius: 5)
    }

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(0..<NotchWindowManager.waveformBarCount, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.86))
                    .frame(width: 3, height: barHeight(index: index))
            }
        }
        .frame(width: 52, height: 18)
        .opacity(manager.state == .finished ? 0.7 : 1.0)
        .animation(.easeOut(duration: 0.09), value: manager.audioLevels)
    }

    private var finishedIcon: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.green)
    }

    private var notchWidth: CGFloat {
        switch manager.state {
        case .collapsed: return manager.notchBaseWidth
        case .active:    return manager.notchBaseWidth + 148
        case .liveText:  return manager.notchBaseWidth + 260
        case .finished:  return manager.notchBaseWidth + 260
        }
    }

    private var notchHeight: CGFloat {
        manager.notchBaseHeight
    }

    private var visibleWingWidth: CGFloat {
        max(0, (notchWidth - manager.notchBaseWidth - 24) / 2)
    }

    private var transcriptWidth: CGFloat {
        min(max(notchWidth, 260), 420)
    }

    private var transcriptText: String {
        manager.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsTranscript: Bool {
        (manager.state == .liveText || manager.state == .finished) && !transcriptText.isEmpty
    }

    private var animation: Animation {
        manager.state == .collapsed ? collapseAnimation : expandAnimation
    }

    private func barHeight(index: Int) -> CGFloat {
        guard manager.state != .collapsed else { return 4 }
        if manager.state == .finished { return 7 }

        let level = manager.audioLevels[index]
        return 4 + CGFloat(level) * 13
    }
}

#Preview {
    NotchRecorderView()
        .environmentObject(NotchWindowManager())
        .frame(width: 520, height: 120)
        .background(Color.gray.opacity(0.25))
}
