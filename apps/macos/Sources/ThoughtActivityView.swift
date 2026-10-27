import SwiftUI
import AppKit
import QuartzCore

/// A quiet AI mark when idle; the large activity field is only mounted during real work.
struct AssistantMark:View {
    var size:CGFloat=30
    var body:some View {
        ZStack {
            Circle().fill(Color(red:0.06,green:0.08,blue:0.15))
            Circle().strokeBorder(AngularGradient(colors:[.cyan,.blue,.purple,.pink,.cyan],center:.center),lineWidth:1.4)
            Text("AI").font(.system(size:size*0.34,weight:.semibold,design:.rounded)).tracking(-0.5).foregroundStyle(.white)
        }.frame(width:size,height:size).accessibilityHidden(true)
    }
}

/// Predetermined motion stays in Core Animation. Only transform/opacity are animated;
/// no per-frame SwiftUI state or layout updates are needed.
struct ThoughtActivityView:NSViewRepresentable {
    let animated:Bool
    var dark=true
    func makeNSView(context:Context)->ThoughtActivityCanvas {ThoughtActivityCanvas()}
    func updateNSView(_ view:ThoughtActivityCanvas,context:Context) {view.setAppearance(dark:dark);view.setMotion(animated)}
}

final class ThoughtActivityCanvas:NSView {
    private let stage=CALayer()
    private var waves:[CAGradientLayer]=[]
    private var aura:[CAGradientLayer]=[]
    private var wantsMotion=false
    private var running=false
    private var observation:NSObjectProtocol?
    private let colors:[NSColor]=[.systemCyan,.systemBlue,.systemPurple,.systemPink]
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer=true;layer=CALayer();layer?.addSublayer(stage)
        for i in 0..<4 {
            let glow=CAGradientLayer();glow.type = .radial
            glow.colors=[colors[i].withAlphaComponent(0.6).cgColor,colors[i].withAlphaComponent(0).cgColor]
            glow.startPoint=CGPoint(x:0.5,y:0.5);glow.endPoint=CGPoint(x:1,y:1)
            aura.append(glow);stage.addSublayer(glow)
            let wave=CAGradientLayer();wave.startPoint=CGPoint(x:0,y:0.5);wave.endPoint=CGPoint(x:1,y:0.5)
            wave.colors=[colors[i].withAlphaComponent(0).cgColor,colors[i].cgColor,colors[(i+1)%4].cgColor,colors[(i+1)%4].withAlphaComponent(0).cgColor]
            wave.locations=[0,0.34,0.66,1];wave.opacity=0.9
            wave.shadowColor=colors[i].cgColor;wave.shadowOpacity=0.65;wave.shadowRadius=5;wave.shadowOffset = .zero
            let mask=CAShapeLayer();mask.fillColor=NSColor.white.cgColor;wave.mask=mask
            waves.append(wave);stage.addSublayer(wave)
        }
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override var intrinsicContentSize:NSSize {NSSize(width:NSView.noIntrinsicMetric,height:48)}
    override func layout() {
        super.layout();CATransaction.begin();CATransaction.setDisableActions(true)
        stage.frame=bounds
        for i in 0..<4 {
            let width=bounds.width*0.74
            let frame=CGRect(x:(bounds.width-width)/2,y:0,width:width,height:bounds.height)
            waves[i].frame=frame
            let path=CGMutablePath()
            // Two sides form a luminous ribbon; the central envelope avoids hard edges.
            for side in [1.0,-1.0] {
                let steps=side>0 ? Array(0...96) : Array((0...96).reversed())
                for step in steps {
                    let x=Double(step)/96
                    let envelope=pow(sin(x * .pi),2)
                    let curve=sin(x * .pi * 2 + Double(i)*0.72)*envelope
                    let y=Double(frame.height)/2+curve*Double(frame.height)*0.30+side*(0.8+envelope*2.4)
                    let point=CGPoint(x:x*Double(frame.width),y:y)
                    if step==0 && side>0 {path.move(to:point)}else{path.addLine(to:point)}
                }
            }
            path.closeSubpath();(waves[i].mask as? CAShapeLayer)?.path=path
            aura[i].frame=CGRect(x:bounds.width*(0.18+Double(i)*0.14)-45,y:-12,width:100,height:76)
        }
        CATransaction.commit();updateMotion()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observation {NotificationCenter.default.removeObserver(observation)}
        observation=nil
        if let window {
            observation=NotificationCenter.default.addObserver(forName:NSWindow.didChangeOcclusionStateNotification,object:window,queue:.main){[weak self] _ in self?.updateMotion()}
        }
        updateMotion()
    }
    private var darkAppearance:Bool?
    func setAppearance(dark:Bool) {
        guard darkAppearance != dark else{return};darkAppearance=dark
        let tones:[NSColor]=dark ? colors : [NSColor(calibratedRed:0,green:0.48,blue:0.64,alpha:1),NSColor(calibratedRed:0.16,green:0.31,blue:0.82,alpha:1),NSColor(calibratedRed:0.52,green:0.20,blue:0.76,alpha:1),NSColor(calibratedRed:0.80,green:0.16,blue:0.48,alpha:1)]
        CATransaction.begin();CATransaction.setDisableActions(true)
        for i in 0..<4 {
            aura[i].colors=[tones[i].withAlphaComponent(dark ? 0.6 : 0.14).cgColor,tones[i].withAlphaComponent(0).cgColor]
            waves[i].colors=[tones[i].withAlphaComponent(0).cgColor,tones[i].cgColor,tones[(i+1)%4].cgColor,tones[(i+1)%4].withAlphaComponent(0).cgColor]
            waves[i].shadowColor=tones[i].cgColor;waves[i].shadowOpacity=dark ? 0.65 : 0.16
        }
        CATransaction.commit()
    }
    func setMotion(_ enabled:Bool) {wantsMotion=enabled;updateMotion()}
    private func updateMotion() {
        let shouldRun=wantsMotion && window?.occlusionState.contains(.visible)==true
        guard shouldRun != running else{return};running=shouldRun
        for i in 0..<4 {
            waves[i].removeAllAnimations();aura[i].removeAllAnimations()
            guard shouldRun else{continue}
            let drift=CABasicAnimation(keyPath:"transform.translation.x")
            drift.fromValue = -14.0;drift.toValue=14.0;drift.duration=2.4;drift.autoreverses=true;drift.repeatCount = .infinity
            drift.timeOffset=Double(i)*0.48;drift.timingFunction=CAMediaTimingFunction(controlPoints:0.77,0,0.175,1)
            waves[i].add(drift,forKey:"drift")
            let breathe=CABasicAnimation(keyPath:"transform.scale.y")
            breathe.fromValue=0.48;breathe.toValue=1.12;breathe.duration=1.6;breathe.autoreverses=true;breathe.repeatCount = .infinity
            breathe.timeOffset=Double(i)*0.36;breathe.timingFunction=CAMediaTimingFunction(controlPoints:0.77,0,0.175,1)
            waves[i].add(breathe,forKey:"breathe")
            let glow=CABasicAnimation(keyPath:"opacity")
            glow.fromValue=0.2;glow.toValue=0.7;glow.duration=1.6;glow.autoreverses=true;glow.repeatCount = .infinity;glow.timeOffset=Double(i)*0.4
            glow.timingFunction=CAMediaTimingFunction(controlPoints:0.77,0,0.175,1)
            aura[i].add(glow,forKey:"glow")
        }
    }
    deinit {if let observation {NotificationCenter.default.removeObserver(observation)}}
}
