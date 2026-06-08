// Minimal iOS/UIKit window — the UIKit object graph a real app builds: a `UIWindow`
// sized to the screen, a root `UIViewController`, then `makeKeyAndVisible`. Bound
// through D's built-in `extern(Objective-C)` + `@selector` (same mechanism the
// objective-d package wraps). See ../index.md (the iOS/UIKit OS-API survey).
//
// > [!IMPORTANT] A real iOS app is launched by `UIApplicationMain`, which
// > instantiates an **app-delegate Objective-C class**. D's interop can *call*
// > Objective-C but cannot *define* new Objective-C classes, so a pure-D UIKit app
// > can't supply the delegate — the delegate is normally written in Objective-C or
// > Swift and calls into D. This file therefore demonstrates the UIKit bindings and
// > the window/VC construction; it is **cross-compiled for the iOS Simulator** for
// > verification (`ldc2 -mtriple=arm64-apple-ios<ver>-simulator`). A full Simulator
// > run (app bundle + `simctl`) is documented in the survey as a manual step.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf;

// Core Graphics geometry (CGFloat == double on 64-bit arm).
extern (C) struct CGPoint
{
    double x, y;
}

extern (C) struct CGSize
{
    double width, height;
}

extern (C) struct CGRect
{
    CGPoint origin;
    CGSize size;
}

extern (Objective-C):

extern class NSObject
{
}

extern class UIResponder : NSObject
{
}

extern class UIScreen : NSObject
{
    static UIScreen mainScreen() @selector("mainScreen");
    CGRect bounds() @selector("bounds");
}

extern class UIViewController : UIResponder
{
    static UIViewController alloc() @selector("alloc");
    UIViewController init() @selector("init");
}

extern class UIWindow : UIResponder
{
    static UIWindow alloc() @selector("alloc");
    UIWindow initWithFrame(CGRect frame) @selector("initWithFrame:");
    void setRootViewController(UIViewController vc) @selector("setRootViewController:");
    void makeKeyAndVisible() @selector("makeKeyAndVisible");
}

extern (D): // back to D linkage

int main()
{
    // Build the minimal UIKit window/VC graph. On the Simulator this is driven from
    // an Objective-C app delegate (see the note above); here it exercises the
    // bindings and is cross-compiled for the iOS Simulator target.
    CGRect bounds = UIScreen.mainScreen().bounds();
    UIWindow win = UIWindow.alloc().initWithFrame(bounds);
    UIViewController root = UIViewController.alloc().init();
    win.setRootViewController(root);
    win.makeKeyAndVisible();
    printf("ok: built a UIWindow + root UIViewController (%.0fx%.0f)\n",
        bounds.size.width, bounds.size.height);
    return 0;
}
