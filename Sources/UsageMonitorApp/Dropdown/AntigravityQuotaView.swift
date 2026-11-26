import SwiftUI
import UsageCore

struct AntigravityQuotaView: View {
    let usage: AntigravityUsage
    let clock: DropdownClock
    let palette: DropdownPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Antigravity")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
            if usage.waitingForLogin {
                Text("Waiting for Antigravity to renew its login")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.warning)
            }
            meter("Gemini", usage.gemini, color: 1)
            if usage.fiveHour != nil || usage.weekly != nil {
                Text("Claude and GPT")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                meter("5-hour", usage.fiveHour, color: 0)
                meter("weekly", usage.weekly, color: 0)
            }
        }
    }

    private func meter(_ label: String, _ quota: AntigravityUsage.Quota?, color: Int) -> some View {
        let bars = quota.map {
            [GaugeBar(alias: label, colorIndex: color, remaining: $0.remaining, greyed: false)]
        } ?? []
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DropdownLayout.gap) {
                Text(label)
                    .foregroundStyle(palette.textSecondary)
                    .frame(width: DropdownLayout.nameWidth, alignment: .leading)
                OverlapLineView(bars: bars, palette: palette, thickness: 6)
                Text(quota.map { DropdownText.percent($0.remaining) } ?? "--")
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: DropdownLayout.numberWidth, alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline) {
                if let quota {
                    let stale = usage.waitingForLogin || quota.observedAt < usage.checkedAt
                    let age = DropdownText.age(quota.observedAt, now: clock.now)
                    Text(stale ? "stale, \(age)" : age)
                        .foregroundStyle(stale ? palette.warning : palette.textMuted)
                    Spacer(minLength: 6)
                    if let resetsAt = quota.resetsAt {
                        Text(DropdownText.countdown(to: resetsAt, now: clock.now))
                            .foregroundStyle(palette.textMuted)
                            .fixedSize()
                    }
                } else if !usage.waitingForLogin {
                    Text("Quota unavailable").foregroundStyle(palette.warning)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .padding(.leading, DropdownLayout.lineInset)
        }
        .font(.system(size: 12).monospacedDigit())
    }
}
