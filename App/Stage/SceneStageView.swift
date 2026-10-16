import LearningCore
import SessionCore
import SwiftUI

/// The scene acted out: a backdrop for the place, the other person and you, and speech bubbles with the lines.
/// Mouths move with the voice that is speaking (and with your microphone on your turn); the characters blink,
/// breathe and turn bright when it's their line. Tap a bubble to hear it again.
struct SceneStageView: View {
    let stage: StageInfo
    let voice: StageVoice?
    let activity: SessionActivity
    /// Read as the characters are drawn, so a change doesn't redraw the whole screen.
    let micLevel: () -> Float
    let focus: FocusInfo?
    let reveal: RevealInfo?
    let partnerLine: ScriptLine?
    let showEnglish: Bool
    let onHearPartner: () -> Void
    let onHearYou: () -> Void

    private var stageSetting: StageSetting { StageSetting(stage) }

    var body: some View {
        let setting = stageSetting
        // Normally you are on the right; playing the colleague, you speak for the character on the left.
        let swapped = stage.learnerPlaysPartner
        let otherTalking = voice == .partner
        let learnerTalking = voice == .you
        let yourTurn = activity == .listening
        let leftTalking = swapped ? learnerTalking : otherTalking
        let rightTalking = swapped ? otherTalking : learnerTalking
        let leftActive = swapped ? (learnerTalking || yourTurn) : otherTalking
        let rightActive = swapped ? otherTalking : (learnerTalking || yourTurn)
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                Group {
                    if swapped { learnerBubble(tailOnLeft: true, active: leftActive) } else { otherBubble(tailOnLeft: true, active: leftActive) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if swapped { otherBubble(tailOnLeft: false, active: rightActive) } else { learnerBubble(tailOnLeft: false, active: rightActive) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(minHeight: 96, alignment: .bottom)

            HStack(alignment: .bottom) {
                StageCharacter(look: .partner(stage, setting: setting), facesRight: true, talking: leftTalking,
                               micLevel: swapped && yourTurn ? micLevel : nil, highlighted: leftActive, seed: 0)
                Spacer(minLength: 8)
                StageCharacter(look: .you(setting: setting), facesRight: false, talking: rightTalking,
                               micLevel: !swapped && yourTurn ? micLevel : nil, highlighted: rightActive, seed: 1.7)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
        }
        .background { StageBackdrop(setting: setting) }
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                if setting.hasTable { StageTable(setting: setting).frame(height: 30) }
                HStack {
                    let colleague = stage.partnerName.isEmpty ? "Colleague" : stage.partnerName
                    nameTag(swapped ? colleague + (yourTurn ? " · you, your turn" : " · you") : colleague)
                    Spacer()
                    nameTag(swapped ? "Your usual part" : (yourTurn ? "You · your turn" : "You"))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scene \(stage.place)")
    }

    private func nameTag(_ name: String) -> some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.45), in: Capsule())
    }

    /// The other side's latest line (the app speaks it).
    @ViewBuilder
    private func otherBubble(tailOnLeft: Bool, active: Bool) -> some View {
        if let line = partnerLine, !line.japanese.isEmpty {
            SpeechBubble(japanese: line.japanese, kana: line.kana, romaji: "", english: line.english,
                         showEnglish: showEnglish, tailOnLeft: tailOnLeft, active: active, action: onHearPartner)
        }
    }

    /// Your line once it's revealed or while you're learning it; before that, just what to say in English.
    @ViewBuilder
    private func learnerBubble(tailOnLeft: Bool, active: Bool) -> some View {
        if let focus {
            if let reveal, reveal.lineID == focus.lineID {
                SpeechBubble(japanese: reveal.japanese, kana: reveal.kana, romaji: reveal.romaji, english: reveal.english,
                             showEnglish: showEnglish, tailOnLeft: tailOnLeft, active: active, action: onHearYou)
            } else if focus.answerShown && !focus.japanese.isEmpty {
                SpeechBubble(japanese: focus.japanese, kana: focus.kana, romaji: focus.romaji, english: focus.english,
                             showEnglish: showEnglish, tailOnLeft: tailOnLeft, active: active, action: onHearYou)
            } else if !focus.cueEn.isEmpty {
                SpeechBubble(japanese: "", kana: "", romaji: "", english: "💭 " + focus.cueEn, showEnglish: true,
                             tailOnLeft: tailOnLeft, active: active, action: onHearYou)
            }
        }
    }
}

/// A speech bubble with a tail toward its speaker.
struct SpeechBubble: View {
    let japanese: String
    let kana: String
    let romaji: String
    let english: String
    let showEnglish: Bool
    let tailOnLeft: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if japanese.isEmpty {
                    Text(english).font(.footnote).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                } else {
                    JapaneseTextView(japanese: japanese, kana: kana, romaji: romaji, english: showEnglish ? english : "",
                                     style: .subheadline)
                }
            }
            .padding(10)
            .frame(maxWidth: 220, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(active ? Palette.line : Palette.hairline, lineWidth: active ? 2 : 1))
            .overlay(alignment: tailOnLeft ? .bottomLeading : .bottomTrailing) {
                BubbleTail(pointsLeft: tailOnLeft)
                    .fill(Palette.surface)
                    .frame(width: 16, height: 10)
                    .offset(x: tailOnLeft ? 26 : -26, y: 9)
            }
            .padding(.bottom, 10)
            .scaleEffect(active ? 1.02 : 1)
            .animation(.easeOut(duration: 0.2), value: active)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays the line again")
    }
}

struct BubbleTail: Shape {
    let pointsLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: pointsLeft ? rect.minX + 2 : rect.maxX - 2, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Characters

/// How a character looks. The colleagues each have their own look; you are always the same.
struct CharacterLook {
    enum Hair { case short, bob, long }

    var skin: Color
    var hair: Color
    var hairStyle: Hair
    var jacket: Color
    var shirt: Color
    var tie: Color?
    var glasses = false
    var hardHat: Color?

    static func partner(_ stage: StageInfo, setting: StageSetting) -> CharacterLook {
        var look: CharacterLook
        switch stage.partnerID {
        case "p.sato":
            look = CharacterLook(skin: .rgb(0xF0C8A4), hair: .rgb(0x9C9C9C), hairStyle: .short, jacket: .rgb(0x2C3E5C),
                                 shirt: .white, tie: .rgb(0x7A2E3A), glasses: true)
        case "p.suzuki":
            look = CharacterLook(skin: .rgb(0xF3CFB0), hair: .rgb(0x3B2A20), hairStyle: .bob, jacket: .rgb(0x3C3C46),
                                 shirt: .rgb(0xF4EDE4))
        case "p.takahashi":
            look = CharacterLook(skin: .rgb(0xEBC29E), hair: .rgb(0x1B1B1F), hairStyle: .short, jacket: .rgb(0x4A4F57),
                                 shirt: .white, tie: .rgb(0x2D5DA8))
        case "p.ito":
            look = CharacterLook(skin: .rgb(0xE0B48C), hair: .rgb(0x1B1B1F), hairStyle: .short, jacket: .rgb(0xF28C28),
                                 shirt: .rgb(0x2E3A4F), hardHat: .rgb(0xF5C518))
        case "p.kobayashi":
            look = CharacterLook(skin: .rgb(0xEFC7A2), hair: .rgb(0x2A2420), hairStyle: .short, jacket: .rgb(0x6B4F3A),
                                 shirt: .rgb(0xE8EEF4), glasses: true)
        case "p.nakamura":
            look = CharacterLook(skin: .rgb(0xF3D0B5), hair: .rgb(0x5A3A28), hairStyle: .long, jacket: .rgb(0x8FB8DE),
                                 shirt: .white)
        default:
            look = stage.partnerGender == .female
                ? CharacterLook(skin: .rgb(0xF3CFB0), hair: .rgb(0x3B2A20), hairStyle: .bob, jacket: .rgb(0x3C3C46), shirt: .white)
                : CharacterLook(skin: .rgb(0xEBC29E), hair: .rgb(0x1B1B1F), hairStyle: .short, jacket: .rgb(0x3A4250),
                                shirt: .white, tie: .rgb(0x2D5DA8))
        }
        if setting == .site && look.hardHat == nil { look.hardHat = .white }
        return look
    }

    static func you(setting: StageSetting) -> CharacterLook {
        var look = CharacterLook(skin: .rgb(0xB07A52), hair: .rgb(0x1E1A18), hairStyle: .short, jacket: .rgb(0x34495E),
                                 shirt: .rgb(0xDCE8F5))
        if setting == .site { look.hardHat = .rgb(0xF5C518) }
        return look
    }
}

/// One character from the waist up, drawn facing the other person. `talking` moves the mouth with the voice;
/// `micLevel` (your turn) moves it with your own voice.
struct StageCharacter: View {
    let look: CharacterLook
    let facesRight: Bool
    let talking: Bool
    let micLevel: (() -> Float)?
    let highlighted: Bool
    let seed: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate + seed
            Canvas { context, size in
                draw(context, size: size, time: time)
            }
        }
        .frame(width: 112, height: 150)
        .background(alignment: .bottom) {
            Ellipse()
                .fill(Palette.signal.opacity(highlighted ? 0.35 : 0))
                .frame(width: 130, height: 90)
                .blur(radius: 18)
                .animation(.easeOut(duration: 0.25), value: highlighted)
        }
        .accessibilityHidden(true)
    }

    /// 0 (closed) … 1 (wide open).
    private func mouthOpening(_ time: Double) -> Double {
        if let micLevel { return min(1, Double(micLevel()) * 3) }
        guard talking else { return 0 }
        return 0.15 + 0.85 * abs(sin(time * 13)) * (0.55 + 0.45 * abs(sin(time * 3.3)))
    }

    private func draw(_ base: GraphicsContext, size: CGSize, time: Double) {
        var context = base
        if !facesRight {
            context.translateBy(x: size.width, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.scaleBy(x: size.width / 100, y: size.height / 150)
        let breathe = reduceMotion ? 0 : sin(time * 2) * 0.8
        let bob = (talking && !reduceMotion) ? sin(time * 9) * 1.2 : 0
        let shade = Color.black.opacity(0.12)

        // Body: jacket, shirt, tie.
        context.fill(Path(roundedRect: CGRect(x: 14, y: 96 + breathe, width: 72, height: 64), cornerRadius: 24),
                     with: .color(look.jacket))
        var vee = Path()
        vee.move(to: CGPoint(x: 40, y: 96 + breathe))
        vee.addLine(to: CGPoint(x: 60, y: 96 + breathe))
        vee.addLine(to: CGPoint(x: 50, y: 120 + breathe))
        vee.closeSubpath()
        context.fill(vee, with: .color(look.shirt))
        if let tie = look.tie {
            var knot = Path()
            knot.move(to: CGPoint(x: 50, y: 99 + breathe))
            knot.addLine(to: CGPoint(x: 54, y: 106 + breathe))
            knot.addLine(to: CGPoint(x: 50, y: 126 + breathe))
            knot.addLine(to: CGPoint(x: 46, y: 106 + breathe))
            knot.closeSubpath()
            context.fill(knot, with: .color(tie))
        }

        // Neck.
        context.fill(Path(CGRect(x: 43, y: 80, width: 14, height: 20)), with: .color(look.skin))
        context.fill(Path(CGRect(x: 43, y: 80, width: 14, height: 8)), with: .color(shade))

        // The head moves a little while talking.
        var head = context
        head.translateBy(x: 0, y: bob)

        if look.hairStyle != .short && look.hardHat == nil {
            let length: CGFloat = look.hairStyle == .long ? 82 : 64
            head.fill(Path(roundedRect: CGRect(x: 20, y: 22, width: 58, height: length), cornerRadius: 24),
                      with: .color(look.hair))
        }
        head.fill(Path(ellipseIn: CGRect(x: 24, y: 24, width: 52, height: 60)), with: .color(look.skin))
        head.fill(Path(ellipseIn: CGRect(x: 21, y: 52, width: 9, height: 12)), with: .color(look.skin))
        head.fill(Path(ellipseIn: CGRect(x: 23.5, y: 55, width: 4, height: 6)), with: .color(shade))

        if look.hardHat == nil {
            var cap = Path()
            cap.move(to: CGPoint(x: 23, y: 58))
            cap.addCurve(to: CGPoint(x: 50, y: 20), control1: CGPoint(x: 19, y: 32), control2: CGPoint(x: 32, y: 20))
            cap.addCurve(to: CGPoint(x: 78, y: 48), control1: CGPoint(x: 68, y: 20), control2: CGPoint(x: 80, y: 30))
            cap.addQuadCurve(to: CGPoint(x: 23, y: 58), control: CGPoint(x: 48, y: 34))
            cap.closeSubpath()
            head.fill(cap, with: .color(look.hair))
        } else {
            head.fill(Path(roundedRect: CGRect(x: 23, y: 42, width: 9, height: 16), cornerRadius: 3), with: .color(look.hair))
        }

        // Eyes blink every few seconds; brows above them.
        let blinking = (time.truncatingRemainder(dividingBy: 3.7)) < 0.13
        for x in [55.0, 69.0] {
            if blinking {
                head.fill(Path(roundedRect: CGRect(x: x - 3, y: 57, width: 6, height: 1.5), cornerRadius: 0.75),
                          with: .color(Color(white: 0.12)))
            } else {
                head.fill(Path(ellipseIn: CGRect(x: x - 2.6, y: 53.5, width: 5.2, height: 6.6)), with: .color(Color(white: 0.12)))
                head.fill(Path(ellipseIn: CGRect(x: x - 0.4, y: 54.5, width: 1.8, height: 1.8)), with: .color(.white))
            }
            let raise: CGFloat = talking ? CGFloat(abs(sin(time * 2.5))) * 1.2 : 0
            head.fill(Path(roundedRect: CGRect(x: x - 4, y: 47 - raise, width: 8, height: 2), cornerRadius: 1),
                      with: .color(look.hair))
        }
        if look.glasses {
            for x in [55.0, 69.0] {
                head.stroke(Path(ellipseIn: CGRect(x: x - 6, y: 51, width: 12, height: 11)), with: .color(Color(white: 0.2)),
                            lineWidth: 1.3)
            }
            var arm = Path()
            arm.move(to: CGPoint(x: 61, y: 56))
            arm.addLine(to: CGPoint(x: 63, y: 56))
            arm.move(to: CGPoint(x: 49, y: 56))
            arm.addLine(to: CGPoint(x: 29, y: 55))
            head.stroke(arm, with: .color(Color(white: 0.2)), lineWidth: 1.3)
        }

        // Nose, cheek, mouth.
        var nose = Path()
        nose.move(to: CGPoint(x: 73, y: 59))
        nose.addQuadCurve(to: CGPoint(x: 71, y: 66), control: CGPoint(x: 77, y: 64))
        head.stroke(nose, with: .color(shade), lineWidth: 1.4)
        head.fill(Path(ellipseIn: CGRect(x: 65, y: 63, width: 9, height: 5)), with: .color(Color.pink.opacity(0.22)))
        let opening = mouthOpening(time)
        if opening < 0.08 {
            var smile = Path()
            smile.move(to: CGPoint(x: 58, y: 71.5))
            smile.addQuadCurve(to: CGPoint(x: 68, y: 71.5), control: CGPoint(x: 63, y: 75))
            head.stroke(smile, with: .color(Color(red: 0.45, green: 0.15, blue: 0.17)), lineWidth: 1.6)
        } else {
            let height = 2 + 8 * opening
            head.fill(Path(ellipseIn: CGRect(x: 58.5, y: 72 - height / 2, width: 9.5, height: height)),
                      with: .color(Color(red: 0.42, green: 0.12, blue: 0.15)))
        }

        if let hat = look.hardHat {
            var dome = Path()
            dome.move(to: CGPoint(x: 21, y: 43))
            dome.addCurve(to: CGPoint(x: 79, y: 43), control1: CGPoint(x: 21, y: 9), control2: CGPoint(x: 79, y: 9))
            dome.closeSubpath()
            head.fill(dome, with: .color(hat))
            head.fill(Path(roundedRect: CGRect(x: 46, y: 15, width: 9, height: 27), cornerRadius: 4.5),
                      with: .color(Color.white.opacity(0.35)))
            head.fill(Path(roundedRect: CGRect(x: 17, y: 40, width: 72, height: 7), cornerRadius: 3.5), with: .color(hat))
            head.fill(Path(roundedRect: CGRect(x: 17, y: 44, width: 72, height: 3), cornerRadius: 1.5), with: .color(shade))
        }
    }
}

// MARK: - Places

/// Where a scene happens, from its place ("at the pier", "at the end of the day").
enum StageSetting: Equatable {
    case site, meetingRoom, office, evening

    init(_ stage: StageInfo) {
        let place = stage.place.lowercased()
        if place.contains("pier") || place.contains("safety") || place.contains("site") {
            self = .site
        } else if place.contains("end of the day") || place.contains("evening") || place.contains("restaurant") {
            self = .evening
        } else if place.contains("office") {
            self = .office
        } else {
            self = .meetingRoom
        }
    }

    /// A table across the front, with the characters sitting behind it.
    var hasTable: Bool { self == .meetingRoom || self == .office }
}

struct StageBackdrop: View {
    let setting: StageSetting

    var body: some View {
        Canvas { context, size in
            switch setting {
            case .site: drawSite(context, size)
            case .meetingRoom: drawMeetingRoom(context, size)
            case .office: drawOffice(context, size)
            case .evening: drawEvening(context, size)
            }
        }
        .accessibilityHidden(true)
    }

    private func rect(_ size: CGSize, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect {
        CGRect(x: size.width * x, y: size.height * y, width: size.width * width, height: size.height * height)
    }

    private func drawSite(_ context: GraphicsContext, _ size: CGSize) {
        let sky = Gradient(colors: [.rgb(0x8EC5F0), .rgb(0xE3F1FC)])
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.65)))
        // The viaduct being built, on its piers.
        context.fill(Path(rect(size, 0, 0.40, 1, 0.05)), with: .color(.rgb(0xB9C2CC)))
        for index in 0..<6 {
            context.fill(Path(rect(size, 0.06 + Double(index) * 0.18, 0.45, 0.035, 0.22)), with: .color(.rgb(0xA6AFBA)))
        }
        // A crane.
        context.fill(Path(rect(size, 0.84, 0.10, 0.014, 0.58)), with: .color(.rgb(0xE0A100)))
        context.fill(Path(rect(size, 0.62, 0.10, 0.34, 0.012)), with: .color(.rgb(0xE0A100)))
        var cable = Path()
        cable.move(to: CGPoint(x: size.width * 0.66, y: size.height * 0.11))
        cable.addLine(to: CGPoint(x: size.width * 0.66, y: size.height * 0.30))
        context.stroke(cable, with: .color(.rgb(0x5A5A5A)), lineWidth: 1)
        // Ground and cones.
        context.fill(Path(rect(size, 0, 0.66, 1, 0.34)), with: .color(.rgb(0xB8A88E)))
        for x in [0.43, 0.52] {
            var cone = Path()
            cone.move(to: CGPoint(x: size.width * x, y: size.height * 0.98))
            cone.addLine(to: CGPoint(x: size.width * (x + 0.035), y: size.height * 0.98))
            cone.addLine(to: CGPoint(x: size.width * (x + 0.0175), y: size.height * 0.86))
            cone.closeSubpath()
            context.fill(cone, with: .color(.rgb(0xF07A1A)))
        }
    }

    private func drawMeetingRoom(_ context: GraphicsContext, _ size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.rgb(0xE9E4DA)))
        // Window.
        context.fill(Path(rect(size, 0.04, 0.08, 0.22, 0.42)), with: .color(.rgb(0xBFDDF2)))
        context.stroke(Path(rect(size, 0.04, 0.08, 0.22, 0.42)), with: .color(.rgb(0xC9C2B4)), lineWidth: 3)
        context.fill(Path(rect(size, 0.148, 0.08, 0.006, 0.42)), with: .color(.rgb(0xC9C2B4)))
        // Whiteboard with a schedule on it.
        context.fill(Path(rect(size, 0.34, 0.07, 0.40, 0.36)), with: .color(.white))
        context.stroke(Path(rect(size, 0.34, 0.07, 0.40, 0.36)), with: .color(.rgb(0xA9A39A)), lineWidth: 2)
        let marker: [UInt32] = [0x2D5DA8, 0x2D5DA8, 0xC0392B]
        for (index, color) in marker.enumerated() {
            let y = 0.14 + Double(index) * 0.08
            context.fill(Path(rect(size, 0.38, y, 0.12 + Double(index) * 0.06, 0.018)), with: .color(.rgb(color)))
        }
        context.fill(Path(rect(size, 0, 0.62, 1, 0.38)), with: .color(.rgb(0xD8D1C4)))
    }

    private func drawOffice(_ context: GraphicsContext, _ size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.rgb(0xF2EEE6)))
        // Morning light through a wide window.
        let light = Gradient(colors: [.rgb(0xFFF4D6), .rgb(0xCFE6F7)])
        context.fill(Path(rect(size, 0.28, 0.06, 0.44, 0.40)),
                     with: .linearGradient(light, startPoint: CGPoint(x: size.width * 0.3, y: 0),
                                           endPoint: CGPoint(x: size.width * 0.7, y: size.height * 0.46)))
        context.stroke(Path(rect(size, 0.28, 0.06, 0.44, 0.40)), with: .color(.rgb(0xCFC8BA)), lineWidth: 3)
        // A plant in the corner.
        context.fill(Path(rect(size, 0.88, 0.48, 0.07, 0.12)), with: .color(.rgb(0x9C6B4A)))
        for (x, y) in [(0.86, 0.36), (0.91, 0.32), (0.95, 0.38), (0.90, 0.42)] {
            context.fill(Path(ellipseIn: rect(size, x - 0.04, y - 0.06, 0.08, 0.12)), with: .color(.rgb(0x5E9C5A)))
        }
        context.fill(Path(rect(size, 0, 0.62, 1, 0.38)), with: .color(.rgb(0xE2DBCD)))
    }

    private func drawEvening(_ context: GraphicsContext, _ size: CGSize) {
        let dusk = Gradient(colors: [.rgb(0x2E3B5E), .rgb(0x6D597A), .rgb(0xE88D67)])
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(dusk, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.7)))
        // Buildings with lit windows.
        let buildings: [(Double, Double, Double)] = [(0.0, 0.30, 0.16), (0.15, 0.20, 0.14), (0.66, 0.26, 0.14), (0.80, 0.16, 0.20)]
        for (x, top, width) in buildings {
            context.fill(Path(rect(size, x, top, width, 0.70 - top)), with: .color(.rgb(0x22223B)))
            var row = top + 0.05
            while row < 0.62 {
                var column = x + 0.02
                while column < x + width - 0.03 {
                    let lit = Int((column + row) * 100) % 3 != 0
                    context.fill(Path(rect(size, column, row, 0.022, 0.03)),
                                 with: .color(lit ? .rgb(0xFFD27D) : .rgb(0x3A3A55)))
                    column += 0.04
                }
                row += 0.07
            }
        }
        // Red lanterns over the restaurant door.
        for x in [0.36, 0.50, 0.64] {
            context.fill(Path(ellipseIn: rect(size, x - 0.03, 0.08, 0.06, 0.12)), with: .color(.rgb(0xD62828)))
            context.fill(Path(ellipseIn: rect(size, x - 0.05, 0.05, 0.10, 0.18)), with: .color(.rgb(0xFF6B4A).opacity(0.25)))
        }
        context.fill(Path(rect(size, 0, 0.70, 1, 0.30)), with: .color(.rgb(0x4A3F4F)))
    }
}

/// The front edge of a table, in front of the characters.
struct StageTable: View {
    let setting: StageSetting

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.rgb(setting == .office ? 0xC9B79C : 0x9C7B5B)).frame(height: 5)
            Rectangle().fill(Color.rgb(setting == .office ? 0xB59F80 : 0x7E6045))
        }
        .accessibilityHidden(true)
    }
}

extension Color {
    /// A fixed colour for the scene drawings (the same in light and dark mode).
    static func rgb(_ value: UInt32) -> Color {
        Color(uiColor: UIColor(hex: value))
    }
}
