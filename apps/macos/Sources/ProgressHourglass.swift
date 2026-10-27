import SwiftUI
import AppKit
import QuartzCore

/// Sand fill represents stored progress; moving grains never advance that value.
struct ProgressHourglass:NSViewRepresentable {
    let progress:Int
    let animated:Bool
    let color:Color
    func makeNSView(context:Context)->HourglassCanvas {HourglassCanvas()}
    func updateNSView(_ view:HourglassCanvas,context:Context) {view.configure(progress:progress,animated:animated,color:NSColor(color))}
}

final class HourglassCanvas:NSView {
    private let outline=CAShapeLayer(),sand=CAShapeLayer(),stream=CAReplicatorLayer(),grain=CAShapeLayer()
    private var value:CGFloat=0
    private var wantsMotion=false,running=false
    private var observer:NSObjectProtocol?
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer=true;layer=CALayer()
        outline.fillColor=nil;outline.lineWidth=1.25;outline.lineCap = .round;outline.lineJoin = .round
        layer?.addSublayer(sand);layer?.addSublayer(stream);layer?.addSublayer(outline)
        stream.instanceCount=3;stream.instanceDelay=0.23;stream.isHidden=true;stream.addSublayer(grain)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func configure(progress:Int,animated:Bool,color:NSColor) {
        value=CGFloat(max(0,min(100,progress)))/100;wantsMotion=animated && progress>0 && progress<100
        CATransaction.begin();CATransaction.setDisableActions(true)
        outline.strokeColor=color.withAlphaComponent(0.65).cgColor;sand.fillColor=color.withAlphaComponent(0.85).cgColor;grain.fillColor=color.cgColor
        CATransaction.commit();needsLayout=true;updateMotion()
    }
    override func layout() {
        super.layout();CATransaction.begin();CATransaction.setDisableActions(true)
        let w=bounds.width,h=bounds.height,c=w/2
        let shape=CGMutablePath();shape.move(to:CGPoint(x:2,y:1));shape.addLine(to:CGPoint(x:w-2,y:1))
        shape.move(to:CGPoint(x:3,y:2));shape.addCurve(to:CGPoint(x:c,y:h/2),control1:CGPoint(x:3,y:h*0.32),control2:CGPoint(x:c-1,y:h*0.40))
        shape.addCurve(to:CGPoint(x:3,y:h-2),control1:CGPoint(x:c-1,y:h*0.6),control2:CGPoint(x:3,y:h*0.68))
        shape.move(to:CGPoint(x:w-3,y:2));shape.addCurve(to:CGPoint(x:c,y:h/2),control1:CGPoint(x:w-3,y:h*0.32),control2:CGPoint(x:c+1,y:h*0.4))
        shape.addCurve(to:CGPoint(x:w-3,y:h-2),control1:CGPoint(x:c+1,y:h*0.6),control2:CGPoint(x:w-3,y:h*0.68))
        shape.move(to:CGPoint(x:2,y:h-1));shape.addLine(to:CGPoint(x:w-2,y:h-1));outline.path=shape
        // AppKit's layer coordinates start at the bottom: completed sand accumulates below.
        let fill=CGMutablePath(),base=h*0.12,span=h*0.30
        let lower=span*value,upper=span*(1-value)
        fill.move(to:CGPoint(x:4,y:base));fill.addLine(to:CGPoint(x:w-4,y:base));fill.addLine(to:CGPoint(x:c,y:base+lower));fill.closeSubpath()
        fill.move(to:CGPoint(x:4,y:h-base));fill.addLine(to:CGPoint(x:w-4,y:h-base));fill.addLine(to:CGPoint(x:c,y:h-base-upper));fill.closeSubpath();sand.path=fill
        stream.frame=bounds;grain.path=CGPath(ellipseIn:CGRect(x:c-0.7,y:h*0.54,width:1.4,height:1.4),transform:nil)
        CATransaction.commit();updateMotion()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow();if let observer {NotificationCenter.default.removeObserver(observer)};observer=nil
        if let window {observer=NotificationCenter.default.addObserver(forName:NSWindow.didChangeOcclusionStateNotification,object:window,queue:.main){[weak self] _ in self?.updateMotion()}}
        updateMotion()
    }
    private func updateMotion() {
        let enabled=wantsMotion && window?.occlusionState.contains(.visible)==true
        guard running != enabled else{return};running=enabled;grain.removeAllAnimations();stream.isHidden = !enabled
        if enabled {
            let fall=CABasicAnimation(keyPath:"transform.translation.y");fall.fromValue=0;fall.toValue = -7;fall.duration=0.7;fall.repeatCount = .infinity
            grain.add(fall,forKey:"fall")
        }
    }
    deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
}
