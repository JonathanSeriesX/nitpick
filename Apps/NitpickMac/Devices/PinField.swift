import SwiftUI

/// Six large digit boxes. Typing advances, Delete in an empty box goes back, pasting fills them, Return submits.
struct PinField: View {
    @Binding var pin: String
    let onSubmit: () -> Void
    @FocusState private var focus: Int?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { i in
                TextField("", text: digit(i))
                    .focused($focus, equals: i)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .frame(width: 40, height: 52)
                    .background(.background, in: .rect(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(focus == i ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: focus == i ? 2 : 1)
                    )
                    .onSubmit(onSubmit)
                    .onKeyPress(.delete) {
                        guard i > 0, i >= pin.count else { return .ignored }
                        pin = String(pin.prefix(i - 1))
                        focus = i - 1
                        return .handled
                    }
                    .accessibilityLabel("Pairing code digit \(i + 1) of 6")
                if i == 2 { Text("–").font(.title2).foregroundStyle(.tertiary).accessibilityHidden(true) }
            }
        }
        .onAppear { focus = min(pin.count, 5) }
    }

    private func digit(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < pin.count ? String(Array(pin)[i]) : "" },
            set: { new in
                let old = i < pin.count ? String(Array(pin)[i]) : ""
                var digits = new.filter(\.isNumber)
                if digits.isEmpty {
                    pin = String(pin.prefix(i))
                    return
                }
                // One extra digit typed into a filled box replaces it; more digits are a paste.
                if digits.count == 2, !old.isEmpty { digits = String(digits.first == old.first ? digits.last! : digits.first!) }
                pin = String((String(pin.prefix(i)) + digits).prefix(6))
                focus = min(pin.count, 5)
            })
    }
}
