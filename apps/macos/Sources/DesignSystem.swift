import SwiftUI
import AppKit
import Combine

private struct ConsoleThemeKey:EnvironmentKey {static let defaultValue=AppTheme.liquidGlass}
extension EnvironmentValues {
    var consoleTheme:AppTheme {get {self[ConsoleThemeKey.self]} set {self[ConsoleThemeKey.self]=newValue}}
}

struct ThemePalette {
    let theme:AppTheme
    var isLiquid:Bool {theme == .liquidGlass}
    var scheme:ColorScheme {isLiquid ? .light : .dark}
    var text:Color {isLiquid ? Color(red:0.07,green:0.12,blue:0.19) : Color(white:0.96)}
    var muted:Color {isLiquid ? Color(red:0.37,green:0.43,blue:0.52) : Color(red:0.66,green:0.71,blue:0.81)}
    var accent:Color {isLiquid ? Color(red:0.10,green:0.40,blue:0.94) : Color(red:0.29,green:0.57,blue:1)}
    var violet:Color {isLiquid ? Color(red:0.38,green:0.36,blue:0.66) : Color(white:0.62)}
    var edge:Color {isLiquid ? Color.white.opacity(0.7) : Color.white.opacity(0.12)}
    var contentEdge:Color {isLiquid ? text.opacity(0.09) : Color.white.opacity(0.075)}
    var card:Color {isLiquid ? Color.white.opacity(0.46) : Color.white.opacity(0.065)}
    var field:Color {isLiquid ? Color.white.opacity(0.48) : Color.black.opacity(0.22)}
    var selection:Color {isLiquid ? accent.opacity(0.11) : Color.white.opacity(0.10)}
    var shadow:Color {isLiquid ? Color(red:0.15,green:0.27,blue:0.36).opacity(0.10) : Color.black.opacity(0.2)}
    var warning:Color {isLiquid ? Color(red:0.64,green:0.27,blue:0.05) : .orange}
    var success:Color {isLiquid ? Color(red:0.10,green:0.45,blue:0.25) : Color(red:0.36,green:0.88,blue:0.58)}
    var danger:Color {isLiquid ? Color(red:0.80,green:0.18,blue:0.24) : Color(red:1,green:0.47,blue:0.47)}
    var spectrum:LinearGradient {LinearGradient(colors:[accent,violet],startPoint:.topLeading,endPoint:.bottomTrailing)}
    // Specular surfaces: a brighter top edge reads as light hitting a thick glass slab.
    func pane(lifted:Bool=false)->LinearGradient {
        LinearGradient(colors:isLiquid ? [Color.white.opacity(lifted ? 0.86 : 0.70),Color.white.opacity(lifted ? 0.62 : 0.44)] : [Color.white.opacity(lifted ? 0.14 : 0.10),Color.white.opacity(lifted ? 0.07 : 0.045)],startPoint:.top,endPoint:.bottom)
    }
    var rim:LinearGradient {
        LinearGradient(colors:isLiquid ? [Color.white.opacity(0.98),Color.white.opacity(0.35),text.opacity(0.07)] : [Color.white.opacity(0.24),Color.white.opacity(0.07),Color.white.opacity(0.03)],startPoint:.top,endPoint:.bottom)
    }
    func tag(_ key:String)->Color {
        let hues:[Color]=isLiquid
            ? [Color(red:0.13,green:0.55,blue:0.86),Color(red:0.52,green:0.36,blue:0.86),Color(red:0.90,green:0.45,blue:0.20),Color(red:0.12,green:0.62,blue:0.52),Color(red:0.86,green:0.30,blue:0.55),Color(red:0.70,green:0.58,blue:0.12)]
            : [Color(red:0.40,green:0.72,blue:1),Color(red:0.72,green:0.58,blue:1),Color(red:1,green:0.66,blue:0.40),Color(red:0.38,green:0.86,blue:0.74),Color(red:1,green:0.52,blue:0.74),Color(red:0.92,green:0.80,blue:0.38)]
        return hues[key.unicodeScalars.reduce(0){$0 &+ Int($1.value)} % hues.count]
    }
}

struct ThemeScope:ViewModifier {
    let theme:AppTheme
    func body(content:Content)->some View {
        let palette=ThemePalette(theme:theme)
        content
            .environment(\.consoleTheme,theme)
            .preferredColorScheme(palette.scheme)
            .foregroundStyle(palette.text)
            .tint(palette.accent)
            .background(ConsoleBackdrop().environment(\.consoleTheme,theme))
    }
}

// One native glass container per surface; repeated task rows remain ordinary content.
struct GlassFamily<Content:View>:View {
    @Environment(\.consoleTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let content:Content
    init(@ViewBuilder content:()->Content) {self.content=content()}
    var body:some View {
        if theme == .liquidGlass,!reduceTransparency {
            if #available(macOS 26.0,*) {GlassEffectContainer(spacing:12){content}}
            else {content}
        } else {content}
    }
}

struct GlassSurface:ViewModifier {
    @Environment(\.consoleTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let radius:CGFloat
    var interactive=false
    var prominent=false
    func body(content:Content)->some View {
        let p=ThemePalette(theme:theme)
        if theme == .liquidGlass,!reduceTransparency {
            if #available(macOS 26.0,*) {
                content.glassEffect(.regular.tint(prominent ? p.accent.opacity(0.17) : nil).interactive(interactive && !reduceMotion),in:.rect(cornerRadius:radius))
            } else {
                content.background(.thinMaterial,in:RoundedRectangle(cornerRadius:radius))
                    .overlay(RoundedRectangle(cornerRadius:radius).strokeBorder(p.edge))
            }
        } else {
            content.background(reduceTransparency ? (theme == .liquidGlass ? Color(white:0.94) : Color(white:0.17)) : p.card,in:RoundedRectangle(cornerRadius:radius))
                .overlay(RoundedRectangle(cornerRadius:radius).strokeBorder(p.contentEdge))
        }
    }
}

struct SelectionSurface:ViewModifier {
    @Environment(\.consoleTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let selected:Bool
    let id:String
    let namespace:Namespace.ID
    func body(content:Content)->some View {
        // Keep labels outside the glass compositor. Native glassEffectID on text
        // intermittently hides adjacent tab labels inside a scrolling macOS container.
        let p=ThemePalette(theme:theme)
        content.background {
            if selected {
                // A raised lens sliding over the native glass track.
                Capsule().fill(reduceTransparency ? AnyShapeStyle(p.isLiquid ? Color.white : Color(white:0.24)) : AnyShapeStyle(p.pane(lifted:true)))
                    .overlay(Capsule().strokeBorder(p.rim,lineWidth:1))
                    .shadow(color:p.shadow.opacity(1.4),radius:6,y:2)
                    .matchedGeometryEffect(id:id,in:namespace)
            }
        }
    }

}

struct ContentSurface:ViewModifier {
    @Environment(\.consoleTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius:CGFloat
    func body(content:Content)->some View {
        let p=ThemePalette(theme:theme)
        let shape=RoundedRectangle(cornerRadius:radius,style:.continuous)
        content.frame(maxWidth:.infinity,alignment:.leading)
            .background(reduceTransparency ? AnyShapeStyle(theme == .liquidGlass ? Color.white : Color(white:0.14)) : AnyShapeStyle(p.pane()),in:shape)
            .overlay(shape.strokeBorder(reduceTransparency ? AnyShapeStyle(p.contentEdge) : AnyShapeStyle(p.rim),lineWidth:1))
    }
}

// Repeated rows stay ordinary content (no native glass per row) but share the specular look.
struct LiquidTile:ViewModifier {
    @Environment(\.consoleTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hovered:Bool
    var radius:CGFloat=16
    func body(content:Content)->some View {
        let p=ThemePalette(theme:theme)
        let shape=RoundedRectangle(cornerRadius:radius,style:.continuous)
        content
            .background(reduceTransparency ? AnyShapeStyle(p.isLiquid ? Color.white : Color(white:hovered ? 0.18 : 0.14)) : AnyShapeStyle(p.pane(lifted:hovered)),in:shape)
            .overlay(shape.strokeBorder(reduceTransparency ? AnyShapeStyle(p.contentEdge) : AnyShapeStyle(p.rim),lineWidth:1))
            .shadow(color:p.shadow.opacity(hovered ? 1.5 : 0.9),radius:hovered ? 14 : 7,y:hovered ? 6 : 3)
            .scaleEffect(hovered && !reduceMotion ? 1.006 : 1)
    }
}

// Each hosting surface owns its own visibility. Hidden popovers stop their timelines.
final class ConsoleMotion:ObservableObject {
    @Published var visible=false

}

struct SurfaceVisibility:NSViewRepresentable {
    let motion:ConsoleMotion
    func makeNSView(context:Context)->VisibilityView {VisibilityView(motion:motion)}
    func updateNSView(_ view:VisibilityView,context:Context) {}
    final class VisibilityView:NSView {
        let motion:ConsoleMotion
        var observer:NSObjectProtocol?
        init(motion:ConsoleMotion){self.motion=motion;super.init(frame:.zero)}
        required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {NotificationCenter.default.removeObserver(observer)}
            observer=NotificationCenter.default.addObserver(forName:NSWindow.didChangeOcclusionStateNotification,object:window,queue:.main){[weak self] _ in self?.updateVisibility()}
            updateVisibility()
        }
        func updateVisibility(){let shown=window?.occlusionState.contains(.visible) == true;DispatchQueue.main.async{[weak self] in self?.motion.visible=shown}}
        deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
    }
}

// Actual backdrop sampling stays behind the content; text never inherits surface opacity.
struct GlassBackdrop:NSViewRepresentable {
    let theme:AppTheme
    func makeNSView(context:Context)->NSVisualEffectView {
        let view=NSVisualEffectView();view.blendingMode = .behindWindow;view.state = .active
        updateNSView(view,context:context);return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {
        view.material = theme == .liquidGlass ? .underWindowBackground : .hudWindow
        view.appearance=NSAppearance(named:theme == .liquidGlass ? .aqua : .darkAqua)
    }
}

struct ConsoleBackdrop:View {
    @Environment(\.consoleTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body:some View {
        ZStack {
            if reduceTransparency {theme == .liquidGlass ? Color(white:0.96) : Color(white:0.11)}
            else {
                GlassBackdrop(theme:theme)
                // Glass only looks like glass when there is colour behind it to refract.
                if theme == .liquidGlass {
                    Color.white.opacity(0.14)
                    aurora([(Color(red:0.35,green:0.80,blue:1),0.34,UnitPoint(x:0.05,y:0.08),360),
                            (Color(red:0.62,green:0.50,blue:1),0.26,UnitPoint(x:0.98,y:0.30),340),
                            (Color(red:1,green:0.62,blue:0.62),0.20,UnitPoint(x:0.10,y:0.80),320),
                            (Color(red:0.40,green:0.62,blue:1),0.22,UnitPoint(x:0.90,y:0.95),340)])
                } else {
                    Color(red:0.025,green:0.04,blue:0.08).opacity(0.80)
                    aurora([(Color(red:0.20,green:0.45,blue:1),0.26,UnitPoint(x:0.05,y:0.08),380),
                            (Color(red:0.55,green:0.30,blue:0.95),0.20,UnitPoint(x:0.98,y:0.45),340),
                            (Color(red:0.10,green:0.70,blue:0.75),0.12,UnitPoint(x:0.15,y:0.92),320)])
                }
            }
        }.overlay(RoundedRectangle(cornerRadius:24).strokeBorder(Color.white.opacity(theme == .liquidGlass ? 0.65 : 0.19)))
            .ignoresSafeArea().accessibilityHidden(true)
    }
    private func aurora(_ blobs:[(Color,Double,UnitPoint,CGFloat)])->some View {
        GeometryReader {geo in
            ZStack {
                ForEach(blobs.indices,id:\.self) {i in
                    let (color,opacity,point,size)=blobs[i]
                    Circle().fill(color.opacity(opacity)).frame(width:size,height:size)
                        .position(x:geo.size.width*point.x,y:geo.size.height*point.y)
                }
            }.blur(radius:80)
        }.allowsHitTesting(false)
    }
}

// Disabled send state has explicit semantic colors; avoid the system plain
// style dimming those colors a second time. Button.disabled still blocks input.
struct SendActionButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        configuration.label.contentShape(RoundedRectangle(cornerRadius:14))
    }
}

struct ConsoleButton:ButtonStyle {
    @Environment(\.consoleTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    var prominent=false
    func makeBody(configuration:Configuration)->some View {
        let p=ThemePalette(theme:theme)
        configuration.label.font(.system(size:12,weight:.semibold))
            .foregroundStyle(prominent && !p.isLiquid ? Color(white:0.07) : prominent ? p.accent : p.text)
            .padding(.horizontal,13).padding(.vertical,9).contentShape(Rectangle())
            .background {
                if prominent && !p.isLiquid {RoundedRectangle(cornerRadius:12).fill(p.accent)}
            }
            .modifier(GlassSurface(radius:12,interactive:true,prominent:prominent))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.46)
            .animation(reduceMotion ? nil : .spring(response:0.25,dampingFraction:0.7),value:configuration.isPressed)
    }
}

extension View {
    func themeScope(_ theme:AppTheme)->some View {modifier(ThemeScope(theme:theme))}
    func themeGlass(radius:CGFloat=16,interactive:Bool=false,prominent:Bool=false)->some View {modifier(GlassSurface(radius:radius,interactive:interactive,prominent:prominent))}
    func consoleCard(radius:CGFloat=16)->some View {modifier(ContentSurface(radius:radius))}
    func liquidTile(hovered:Bool,radius:CGFloat=16)->some View {modifier(LiquidTile(hovered:hovered,radius:radius))}
    func selectionGlass(_ selected:Bool,id:String,in namespace:Namespace.ID)->some View {modifier(SelectionSurface(selected:selected,id:id,namespace:namespace))}
}

