import SwiftUI

// "Orca's private AI": onboarding step, top-bar progress, Home reminder, Settings page.
// The pitch is privacy (it runs on this Mac, which is why it's a download) plus a real before/after.

private let unlockPurple = Color(hex: 0x7A4DE6)

private struct SkillIcon: View {
    let skill: PrivateAI.Skill
    var body: some View {
        Image(systemName: skill.symbol).font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.Tone.magic.fg)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.Tone.magic.bg))
    }
}

private struct UnlockBar: View {
    let fraction: Double
    var width: CGFloat = 96
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(DS.tertiary)
            Capsule().fill(unlockPurple).frame(width: max(3, width * fraction))
        }
        .frame(width: width, height: 5)
    }
}

/// What a skill's row shows on the right, wherever it appears.
private struct SkillState: View {
    let skill: PrivateAI.Skill
    var compact = false
    var ai = PrivateAI.shared
    var body: some View {
        switch ai.state(skill) {
        case .unlocked: Badge("Unlocked ✓", tone: .success)
        case .unlocking(let f):
            VStack(alignment: .trailing, spacing: 4) {
                Text(f <= 0.001 ? "Waiting…" : "\(Int(f * 100))% of \(skill.sizeLabel)").font(DS.caption).foregroundStyle(DS.text2)
                UnlockBar(fraction: f, width: compact ? 80 : 96)
            }
        case .preparing: Text("Getting it ready…").font(DS.caption).foregroundStyle(DS.text2)
        case .failed(let m): Text(m).font(DS.caption).foregroundStyle(DS.Tone.critical.fg).lineLimit(2).frame(maxWidth: 160, alignment: .trailing)
        case .locked: Text(skill.sizeLabel).font(DS.bodySM).foregroundStyle(DS.text2)
        }
    }
}

// MARK: - Onboarding step 2

struct PrivateAIOnboarding: View {
    let onDone: () -> Void
    var ai = PrivateAI.shared
    @State private var picked: Set<PrivateAI.Skill> = []

    private var offered: [PrivateAI.Skill] { ai.available }
    private var total: Int64 { picked.filter { !ai.isUnlocked($0) }.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: 0x30A46C)).frame(width: 8, height: 8)
                Text("Folders").font(DS.caption).foregroundStyle(DS.text2)
                Rectangle().fill(DS.border).frame(width: 18, height: 1)
                Circle().fill(DS.text).frame(width: 8, height: 8)
                Text("Private AI").font(DS.bodySM).foregroundStyle(DS.text)
            }
            Text("Unlock Orca’s private AI").font(DS.display).foregroundStyle(DS.text)
            Text("Orca can understand your photos, erase things from them and hear you clearly. Most apps upload your files to do this. Orca does it all on this Mac, so it needs a one-time download.")
                .font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            BeforeAfter()
            VStack(spacing: 0) {
                ForEach(Array(offered.enumerated()), id: \.element) { i, s in
                    Button { toggle(s) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: picked.contains(s) || ai.isUnlocked(s) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 16)).foregroundStyle(picked.contains(s) || ai.isUnlocked(s) ? DS.brand : DS.text3)
                            SkillIcon(skill: s)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(s.title).font(DS.body).foregroundStyle(DS.text)
                                    Badge("Recommended", tone: .magic)
                                }
                                Text(s.pitch).font(DS.caption).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            SkillState(skill: s)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(ai.isUnlocked(s) || ai.isWorking(s))
                    if i < offered.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.surface2))
            HStack {
                Text(total > 0 ? "One-time download · \(Fmt.size(total)) · free" : "Nothing to download").font(DS.bodySM).foregroundStyle(DS.text)
                Spacer()
                Text("Works offline after that").font(DS.caption).foregroundStyle(DS.text2)
            }
            HStack(spacing: 10) {
                Badge("Your files never leave this Mac", tone: .success)
                Spacer()
                Button("Maybe later") { onDone() }.buttonStyle(.plainP)
                Button(buttonTitle) {
                    ai.unlock(PrivateAI.Skill.allCases.filter { picked.contains($0) })
                    onDone()
                }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { picked = Set(offered.filter { !ai.isUnlocked($0) }) }
    }

    private var buttonTitle: String {
        let n = picked.filter { !ai.isUnlocked($0) }.count
        if n == 0 { return "Start searching" }
        return n == offered.filter { !ai.isUnlocked($0) }.count ? "Unlock all & start" : "Unlock \(n) & start"
    }

    private func toggle(_ s: PrivateAI.Skill) {
        if picked.contains(s) { picked.remove(s) } else { picked.insert(s) }
    }
}

/// Why it matters, shown not claimed: a description that names nothing in the files.
private struct BeforeAfter: View {
    var body: some View {
        HStack(spacing: 10) {
            panel(label: "WITHOUT", magic: false) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("0 files").font(DS.stat).foregroundStyle(DS.text2)
                    Text("none are named “holiday”").font(DS.caption).foregroundStyle(DS.text2)
                }
            }
            panel(label: "WITH ORCA’S PRIVATE AI", magic: true) {
                HStack(spacing: 6) {
                    ForEach([("sun.horizon.fill", 0x5AA9E6, 0xF6C26B), ("sailboat.fill", 0x2F7FB8, 0x9ED8F0), ("beach.umbrella.fill", 0x3BA7A0, 0xF2DFA7)], id: \.0) { sym, a, b in
                        Image(systemName: sym).font(.system(size: 14)).foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Color(hex: UInt32(a)), Color(hex: UInt32(b))], startPoint: .top, endPoint: .bottom)))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Your seaside photos").font(DS.bodySM).foregroundStyle(DS.Tone.magic.fg)
                        Text("found by what’s in them").font(DS.caption).foregroundStyle(DS.Tone.magic.fg)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func panel<C: View>(label: String, magic: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(DS.label).tracking(0.6).foregroundStyle(magic ? DS.Tone.magic.fg : DS.text2)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
                Text("our holiday by the sea").font(DS.caption)
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: false)
        .background(RoundedRectangle(cornerRadius: 10).fill(magic ? DS.Tone.magic.bg : DS.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(magic ? .clear : DS.border))
    }
}

// MARK: - Top bar: "Unlocking AI · 62%"

struct PrivateAIPill: View {
    var ai = PrivateAI.shared
    @State private var open = false
    var body: some View {
        if ai.isBusy {
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(0.03, ai.overallProgress)).stroke(unlockPurple, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    Text("Unlocking AI · \(Int(ai.overallProgress * 100))%").font(DS.caption).foregroundStyle(DS.onDark)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(DS.topbarField))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).handCursor()
            .popover(isPresented: $open, arrowEdge: .bottom) { PrivateAIPopover().environment(AppState.shared) }
            .help("Orca’s private AI is downloading")
        }
    }
}

private struct PrivateAIPopover: View {
    var ai = PrivateAI.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Orca’s private AI").font(DS.body).foregroundStyle(DS.text)
            ForEach(ai.available) { s in
                HStack(spacing: 8) {
                    Text(s.title).font(DS.bodySM).foregroundStyle(DS.text)
                    Spacer()
                    SkillState(skill: s, compact: true)
                    if ai.isWorking(s) {
                        Button { ai.cancel(s) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.text2) }
                            .buttonStyle(.plain).help("Stop")
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 10))
                Text("Runs on this Mac. Find it any time in Settings › Private AI.").font(DS.caption)
            }
            .foregroundStyle(DS.text2)
        }
        .padding(16)
        .frame(width: 330)
    }
}

// MARK: - Home: one gentle reminder

struct PrivateAIReminder: View {
    var ai = PrivateAI.shared
    var body: some View {
        if ai.showsReminder {
            let skills = ai.reminderSkills
            let size = skills.reduce(Int64(0)) { $0 + $1.bytes }
            HStack(spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 16, weight: .medium)).foregroundStyle(DS.Tone.magic.fg)
                    .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10).fill(DS.Tone.magic.bg))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Orca can do much more with your photos").font(DS.body).foregroundStyle(DS.text)
                        Badge("Recommended", tone: .magic)
                    }
                    Text(skills.count > 1
                         ? "Unlock photo understanding and the Pro eraser: search what’s inside your pictures, remove things in one stroke. Private, on this Mac. One time, \(Fmt.size(size))."
                         : "\(skills[0].pitch) Private, on this Mac. One time, \(Fmt.size(size)).")
                        .font(DS.caption).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Don’t remind me") { ai.reminderNever() }.buttonStyle(.plainP)
                Button("Maybe later") { ai.reminderLater() }.buttonStyle(.secondary)
                Button(skills.count > 1 ? "Unlock both" : "Unlock") { ai.unlock(skills) }.buttonStyle(.primary)
            }
            .padding(14)
            .frame(maxWidth: 1000)
            .card(14)
        }
    }
}

// MARK: - Settings › Private AI

struct PrivateAISettings: View {
    var ai = PrivateAI.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                PixelLabel("Private AI · runs on this Mac, never in the cloud")
                VStack(spacing: 0) {
                    ForEach(Array(ai.available.enumerated()), id: \.element) { i, s in
                        HStack(spacing: 12) {
                            SkillIcon(skill: s)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(s.title).font(DS.body).foregroundStyle(DS.text)
                                    if case .locked = ai.state(s) { Badge("Recommended", tone: .magic) }
                                }
                                Text(s.pitch).font(DS.caption).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            actions(s)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        if i < ai.available.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.surface2))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border))
            }
            VStack(alignment: .leading, spacing: 8) {
                PixelLabel("Built in")
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Quick eraser, background removal, reading text, translation").font(DS.body).foregroundStyle(DS.text)
                        Text("Always on. Nothing to download.").font(DS.caption).foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Badge("On", tone: .success)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.surface2))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border))
            }
            Toggle(isOn: Binding(get: { ai.remindersOn }, set: { ai.remindersOn = $0 })) {
                Text("Remind me about skills I haven’t unlocked").font(DS.body).foregroundStyle(DS.text)
            }
            .toggleStyle(.switch)
            HStack(spacing: 8) {
                Image(systemName: "lock")
                Text("Your files are never uploaded. That’s why these are downloads: the AI comes to your files, not the other way round.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DS.bodySM).foregroundStyle(DS.Tone.success.fg)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.Tone.success.bg))
        }
    }

    @ViewBuilder
    private func actions(_ s: PrivateAI.Skill) -> some View {
        switch ai.state(s) {
        case .unlocked:
            HStack(spacing: 8) {
                Badge("Unlocked · \(s.sizeLabel)", tone: .success)
                Button("Remove") { ai.remove(s) }.buttonStyle(.plainP)
            }
        case .unlocking, .preparing:
            HStack(spacing: 8) {
                SkillState(skill: s)
                Button("Stop") { ai.cancel(s) }.buttonStyle(.secondary)
            }
        case .failed:
            HStack(spacing: 8) {
                SkillState(skill: s)
                Button("Try again") { ai.unlock([s]) }.buttonStyle(.primary)
            }
        case .locked:
            Button("Unlock · \(s.sizeLabel)") { ai.unlock([s]) }.buttonStyle(.primary)
        }
    }
}
