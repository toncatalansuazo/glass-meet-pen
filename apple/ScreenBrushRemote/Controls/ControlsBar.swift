import BrushKit
import SwiftUI

/// Tool controls. Horizontal bottom bar on compact layouts (iPhone portrait);
/// vertical side rail on regular width or compact height (iPad, iPhone landscape).
struct ControlsBar: View {
    @ObservedObject var model: RemoteModel
    let vertical: Bool

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
            layout {
                modeToggle
                separator
                toolMenu
                colorMenu
                widthMenu
                separator
                iconButton("arrow.uturn.backward", "Undo") { model.undo() }
                iconButton("arrow.uturn.forward", "Redo") { model.redo() }
                iconButton("trash", "Clear all") { model.clear() }
                iconButton("arrow.down.right.and.arrow.up.left", "Fit") { model.requestFit() }
                separator
                macModeToggle
            }
            .padding(vertical ? .vertical : .horizontal, 12)
            .padding(vertical ? .horizontal : .vertical, 8)
        }
        .fixedSize(horizontal: vertical, vertical: !vertical)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.15))
            .frame(width: vertical ? 28 : 1, height: vertical ? 1 : 28)
    }

    private var modeToggle: some View {
        Button {
            model.mode = model.mode == .paint ? .navigate : .paint
        } label: {
            Label(model.mode == .paint ? "Paint" : "Move", systemImage: model.mode == .paint ? "paintbrush.pointed.fill" : "hand.draw")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 46, height: 46)
                .foregroundStyle(.white)
                .background(model.mode == .paint ? Color.accentColor : Color.gray, in: Circle())
        }
        .accessibilityLabel(model.mode == .paint ? "Paint mode. Tap for move and zoom mode" : "Move and zoom mode. Tap for paint mode")
    }

    private var toolMenu: some View {
        Menu {
            Picker("Tool", selection: $model.toolState.tool) {
                ForEach(Tool.phoneTools, id: \.self) { tool in
                    Label(tool.displayName, systemImage: tool.symbolName).tag(tool)
                }
            }
        } label: {
            Image(systemName: model.toolState.tool.symbolName)
                .font(.title3)
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("Tool: \(model.toolState.tool.displayName)")
    }

    private var colorMenu: some View {
        Menu {
            ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { index, color in
                Button {
                    model.toolState.color = color
                } label: {
                    Label(Self.colorNames[index], systemImage: model.toolState.color == color ? "checkmark.circle.fill" : "circle.fill")
                }
                .tint(color.swiftUI)
            }
        } label: {
            Circle()
                .fill(model.toolState.color.swiftUI)
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2))
                .frame(width: 28, height: 28)
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("Color")
    }

    private var widthMenu: some View {
        Menu {
            Picker("Width", selection: $model.toolState.width) {
                ForEach(WidthPreset.allCases, id: \.self) { w in
                    Text("\(Int(w.points)) pt").tag(w)
                }
            }
        } label: {
            Circle().fill(Color.primary)
                .frame(width: CGFloat(model.toolState.width.points) + 4, height: CGFloat(model.toolState.width.points) + 4)
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("Width \(Int(model.toolState.width.points)) points")
    }

    private var macModeToggle: some View {
        Button {
            model.setMacDrawMode(!model.macDrawMode)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: model.macDrawMode ? "cursorarrow.click.badge.clock" : "cursorarrow")
                    .font(.body)
                Text(model.macDrawMode ? "Mac: draw" : "Mac: click")
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(width: 52, height: 40)
            .foregroundStyle(model.macDrawMode ? Color.accentColor : Color.primary)
        }
        .accessibilityLabel(model.macDrawMode ? "Mac draw mode on" : "Mac draw mode off")
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).frame(width: 40, height: 40)
        }
        .accessibilityLabel(label)
    }

    static let colorNames = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "White", "Black"]
}

extension RGBAColor {
    var swiftUI: Color { Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a)) }
}
