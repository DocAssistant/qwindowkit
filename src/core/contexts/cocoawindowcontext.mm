// Copyright (C) 2023-2024 Stdware Collections (https://www.github.com/stdware)
// Copyright (C) 2021-2023 wangwenx190 (Yuhang Zhao)
// SPDX-License-Identifier: Apache-2.0

#include "cocoawindowcontext_p.h"

#include <objc/runtime.h>
#include <AppKit/AppKit.h>

#include <Cocoa/Cocoa.h>

#include <QtGui/QGuiApplication>
#include <functional>

#include "qwkglobal_p.h"
#include "systemwindow_p.h"

// https://forgetsou.github.io/2020/11/06/macos%E5%BC%80%E5%8F%91-%E5%85%B3%E9%97%AD-%E6%9C%80%E5%B0%8F%E5%8C%96-%E5%85%A8%E5%B1%8F%E5%B1%85%E4%B8%AD%E5%A4%84%E7%90%86(%E4%BB%BFMac%20QQ)/
// https://nyrra33.com/2019/03/26/changing-titlebars-height/

namespace QWK {

    struct NSWindowProxy;

    using ProxyList = QHash<WId, NSWindowProxy *>;
    Q_GLOBAL_STATIC(ProxyList, g_proxyList);
}

struct QWK_NSWindowDelegate {
public:
    enum NSEventType {
        WillEnterFullScreen,
        DidEnterFullScreen,
        WillExitFullScreen,
        DidExitFullScreen,
        DidResize,
    };

    virtual ~QWK_NSWindowDelegate() = default;
    virtual void windowEvent(NSEventType eventType) = 0;
};

//
// Objective C++ Begin
//

// 标准窗口按钮绘制时会向承载视图查询 _mouseInGroup:。这是 AppKit 的非公开
// 容器协议，集中封装于 macOS 适配层；按钮图像、点击动作及辅助功能仍由系统提供。
// 系统升级须运行 nativeMacDialogChrome 的原生悬停像素回归。
@interface QWK_SystemButtonHost : NSView {
    NSTrackingArea *trackingArea_;
    BOOL mouseInside_;
}
@end

@implementation QWK_SystemButtonHost
- (void)refreshButtons {
    for (NSButton *button in self.subviews) {
        // macOS 26 的系统按钮缓存图像，仅置 needsDisplay 不能切换叉号。
        // 在支持该协议时先刷新系统悬停图像；旧系统仍走正常重绘。
        const SEL refreshHover = NSSelectorFromString(@"mouseEnteredOrExited");
        if ([button respondsToSelector:refreshHover])
            [button performSelector:refreshHover];
        [button setNeedsDisplay:YES];
    }
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (trackingArea_) {
        [self removeTrackingArea:trackingArea_];
        [trackingArea_ release];
    }
    trackingArea_ = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:trackingArea_];
    const NSPoint pointer = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    mouseInside_ = self.window && !self.hidden && NSPointInRect(pointer, self.bounds);
    [self refreshButtons];
}
- (BOOL)_mouseInGroup:(NSButton *)button {
    Q_UNUSED(button);
    return mouseInside_;
}
- (void)mouseEntered:(NSEvent *)event {
    Q_UNUSED(event);
    mouseInside_ = YES;
    [self refreshButtons];
}
- (void)mouseExited:(NSEvent *)event {
    Q_UNUSED(event);
    mouseInside_ = NO;
    [self refreshButtons];
}
- (void)dealloc {
    if (trackingArea_) {
        [self removeTrackingArea:trackingArea_];
        [trackingArea_ release];
    }
    [super dealloc];
}
@end

@interface QWK_NSWindowObserver : NSObject {
}
@end

@implementation QWK_NSWindowObserver

- (id)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowWillEnterFullScreen:)
                                                     name:NSWindowWillEnterFullScreenNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidEnterFullScreen:)
                                                     name:NSWindowDidEnterFullScreenNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowWillExitFullScreen:)
                                                     name:NSWindowWillExitFullScreenNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidExitFullScreen:)
                                                     name:NSWindowDidExitFullScreenNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidResize:)
                                                     name:NSWindowDidResizeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    auto nswindow = reinterpret_cast<NSWindow *>(notification.object);
    auto nsview = [nswindow contentView];
    if (auto proxy = QWK::g_proxyList->value(reinterpret_cast<WId>(nsview))) {
        reinterpret_cast<QWK_NSWindowDelegate *>(proxy)->windowEvent(
            QWK_NSWindowDelegate::WillEnterFullScreen);
    }
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    auto nswindow = reinterpret_cast<NSWindow *>(notification.object);
    auto nsview = [nswindow contentView];
    if (auto proxy = QWK::g_proxyList->value(reinterpret_cast<WId>(nsview))) {
        reinterpret_cast<QWK_NSWindowDelegate *>(proxy)->windowEvent(
            QWK_NSWindowDelegate::DidEnterFullScreen);
    }
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
    auto nswindow = reinterpret_cast<NSWindow *>(notification.object);
    auto nsview = [nswindow contentView];
    if (auto proxy = QWK::g_proxyList->value(reinterpret_cast<WId>(nsview))) {
        reinterpret_cast<QWK_NSWindowDelegate *>(proxy)->windowEvent(
            QWK_NSWindowDelegate::WillExitFullScreen);
    }
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    auto nswindow = reinterpret_cast<NSWindow *>(notification.object);
    auto nsview = [nswindow contentView];
    if (auto proxy = QWK::g_proxyList->value(reinterpret_cast<WId>(nsview))) {
        reinterpret_cast<QWK_NSWindowDelegate *>(proxy)->windowEvent(
            QWK_NSWindowDelegate::DidExitFullScreen);
    }
}

- (void)windowDidResize:(NSNotification *)notification {
    auto nswindow = reinterpret_cast<NSWindow *>(notification.object);
    auto nsview = [nswindow contentView];
    if (auto proxy = QWK::g_proxyList->value(reinterpret_cast<WId>(nsview))) {
        reinterpret_cast<QWK_NSWindowDelegate *>(proxy)->windowEvent(
            QWK_NSWindowDelegate::DidResize);
    }
}

@end

@interface QWK_NSViewObserver : NSObject
- (instancetype)initWithProxy:(QWK::NSWindowProxy*)proxy;
@end

//
// Objective C++ End
//

namespace QWK {

    struct NSWindowProxy : public QWK_NSWindowDelegate {
        enum class BlurMode {
            Dark,
            Light,
            None,
        };

        NSWindowProxy(NSView *macView) {
            nsview = macView;

            observer = [[QWK_NSViewObserver alloc] initWithProxy:this];
            [nsview addObserver:observer
                     forKeyPath:@"window"
                        options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                        context:nil];
        }

        ~NSWindowProxy() override {
            restoreCloseButtonParent();
            [nsview removeObserver:observer forKeyPath:@"window"];
            [observer release];
        }

        // Delegate
        void windowEvent(NSEventType eventType) override {
            switch (eventType) {
                case WillExitFullScreen: {
                    auto nswindow = [nsview window];
                    nswindow.titleVisibility = NSWindowTitleHidden;
                    if (!screenRectCallback || !systemButtonVisible)
                        return;

                    // The system buttons will stuck at their default positions when the
                    // exit-fullscreen animation is running, we need to hide them until the
                    // animation finishes
                    for (const auto &button : systemButtons()) {
                        button.hidden = true;
                    }
                    break;
                }

                case DidExitFullScreen: {
                    if (!screenRectCallback || !systemButtonVisible)
                        return;

                    for (const auto &button : systemButtons()) {
                        button.hidden = false;
                    }
                    updateSystemButtonRect();
                    break;
                }

                case DidResize: {
                    if (!screenRectCallback || !systemButtonVisible) {
                        return;
                    }
                    updateSystemButtonRect();
                    break;
                }

                case DidEnterFullScreen: {
                    auto nswindow = [nsview window];
                    nswindow.titleVisibility = NSWindowTitleVisible;
                    break;
                }

                default:
                    break;
            }
        }

        void setCloseButtonOnly(bool enabled) {
            if (!enabled)
                restoreCloseButtonParent();
            closeButtonOnly = enabled;
            setSystemButtonVisible(systemButtonVisible);
        }

        void setTitleBarHitTest(const std::function<bool(const QPoint &)> &callback,
                               const std::function<void()> &doubleClick) {
            titleBarHitTest_ = callback;
            titleBarDoubleClick_ = doubleClick;
        }

        bool handleNativeDrag(NSEvent *event) {
            if (event.type != NSEventTypeLeftMouseDown || !titleBarHitTest_)
                return false;
            auto window = nsview.window;
            if (!window || (window.styleMask & NSWindowStyleMaskFullScreen))
                return false;
            const NSPoint local = [nsview convertPoint:event.locationInWindow fromView:nil];
            for (const auto button : systemButtons()) {
                if (button && !button.hidden &&
                    NSPointInRect(local, [button convertRect:button.bounds toView:nsview]))
                    return false;
            }
            const QPoint scene(qRound(local.x), qRound(nsview.isFlipped ? local.y : nsview.bounds.size.height - local.y));
            if (!titleBarHitTest_(scene))
                return false;
            if (event.clickCount % 2 == 0) {
                if (titleBarDoubleClick_)
                    titleBarDoubleClick_();
                return true;
            }
            // Qt Quick 可能把整段鼠标序列延后处理，此时 NSApp.currentEvent 已是 mouseUp。
            // 在 AppKit 分发原生 mouseDown 时接管，保留真实事件与系统触摸板拖移行为。
            [window performWindowDragWithEvent:event];
            return true;
        }

        // System buttons visibility
        void setSystemButtonVisible(bool visible) {
            systemButtonVisible = visible;
            closeButtonHost_.hidden = !visible;
            const bool closeOnly = closeButtonOnly || !(nsview.window.styleMask & NSWindowStyleMaskMiniaturizable);
            const auto buttons = systemButtons();
            for (size_t i = 0; i < buttons.size(); ++i) {
                buttons[i].hidden = !visible || (closeOnly && i != 0);
            }

            if (!screenRectCallback || !visible) {
                return;
            }
            updateSystemButtonRect();
        }

        // System buttons area
        void setScreenRectCallback(const ScreenRectCallback &callback) {
            screenRectCallback = callback;

            if (!callback || !systemButtonVisible) {
                return;
            }
            updateSystemButtonRect();
        }

        void updateSystemButtonRect() {
            if (!screenRectCallback || !systemButtonVisible) {
                return;
            }
            const auto &buttons = systemButtons();
            const auto &leftButton = buttons[0];
            const auto &midButton = buttons[1];
            const auto &rightButton = buttons[2];

            // 对话框可能没有最小化/缩放按钮，不能从 nil 读取零尺寸来定位关闭按钮。
            NSButton *reference = midButton ? midButton : (leftButton ? leftButton : rightButton);
            if (!reference || !reference.superview) {
                return;
            }
            auto titlebar = reference.superview;
            int titlebarHeight = closeButtonParent_ ? closeButtonParent_.frame.size.height : titlebar.frame.size.height;
            auto width = reference.frame.size.width;
            auto height = reference.frame.size.height;
            auto spacing = leftButton && midButton
                ? midButton.frame.origin.x - leftButton.frame.origin.x
                : (leftButton && rightButton
                    ? (rightButton.frame.origin.x - leftButton.frame.origin.x) / 2
                    : width + 6);

            auto viewSize = nsview.frame.size;
            // QRect::center() 对偶数高度向上偏一像素；使用几何中心与 QML 标题对齐。
            QPointF center = QRectF(screenRectCallback(QSize(viewSize.width, titlebarHeight))).center();

            // 用视图转换处理标题栏容器偏移与 flipped 坐标，而非假设其原点在窗口顶部。
            NSPoint contentCenter = NSMakePoint(center.x(),
                nsview.isFlipped ? center.y() : viewSize.height - center.y());
            NSPoint buttonCenter = [nsview convertPoint:contentCenter toView:titlebar];
            center = QPointF(buttonCenter.x, buttonCenter.y);

            // 仅含关闭按钮的对话框以该按钮居中，不再预留完整交通灯组。
            const bool closeOnly = closeButtonOnly || !([nsview window].styleMask & NSWindowStyleMaskMiniaturizable);
            if (closeOnly) {
                midButton.hidden = YES;
                rightButton.hidden = YES;
                // 自绘标题在客户区内，用独立的原生承载视图同步真实跟踪区域。
                if (leftButton && (hostedCloseButton_ != leftButton || leftButton.superview != closeButtonHost_)) {
                    restoreCloseButtonParent();
                    hostedCloseButton_ = [leftButton retain];
                    closeButtonParent_ = [leftButton.superview retain];
                    closeButtonOriginalFrame_ = leftButton.frame;
                    closeButtonHost_ = [[QWK_SystemButtonHost alloc] initWithFrame:NSZeroRect];
                    // 放在原生窗口框架内，避免 Qt 内容视图过滤原生按钮的辅助功能节点。
                    [nsview.superview addSubview:closeButtonHost_ positioned:NSWindowAbove relativeTo:nil];
                    [closeButtonHost_ addSubview:leftButton];
                }
                const NSSize size = leftButton.frame.size;
                const NSPoint hostCenter = [nsview convertPoint:contentCenter toView:closeButtonHost_.superview];
                [closeButtonHost_ setFrame:NSMakeRect(hostCenter.x - size.width / 2,
                    hostCenter.y - size.height / 2, size.width, size.height)];
                [leftButton setFrameOrigin:NSZeroPoint];
                [closeButtonHost_ updateTrackingAreas];
                return;
            }

            // Mid button
            NSPoint centerOrigin = {
                center.x() - width / 2,
                center.y() - height / 2,
            };
            [midButton setFrameOrigin:centerOrigin];

            // Left button
            NSPoint leftOrigin = {
                centerOrigin.x - spacing,
                centerOrigin.y,
            };
            [leftButton setFrameOrigin:leftOrigin];

            // Right button
            NSPoint rightOrigin = {
                centerOrigin.x + spacing,
                centerOrigin.y,
            };
            [rightButton setFrameOrigin:rightOrigin];
        }

        inline std::array<NSButton *, 3> systemButtons() {
            auto nswindow = [nsview window];
            if (!nswindow) {
                return {nullptr, nullptr, nullptr};
            }
            NSButton *closeBtn = [nswindow standardWindowButton:NSWindowCloseButton];
            NSButton *minimizeBtn = [nswindow standardWindowButton:NSWindowMiniaturizeButton];
            NSButton *zoomBtn = [nswindow standardWindowButton:NSWindowZoomButton];
            return {closeBtn, minimizeBtn, zoomBtn};
        }

        void restoreCloseButtonParent() {
            if (hostedCloseButton_ && closeButtonParent_) {
                [closeButtonParent_ addSubview:hostedCloseButton_];
                [hostedCloseButton_ setFrame:closeButtonOriginalFrame_];
            }
            [closeButtonHost_ removeFromSuperview];
            [closeButtonHost_ release];
            [hostedCloseButton_ release];
            [closeButtonParent_ release];
            closeButtonHost_ = nil;
            hostedCloseButton_ = nil;
            closeButtonParent_ = nil;
        }

        inline int titleBarHeight() const {
            auto nswindow = [nsview window];
            if (!nswindow)
                return 0;
            NSButton *closeBtn = [nswindow standardWindowButton:NSWindowCloseButton];
            NSView *titlebar = closeBtn == hostedCloseButton_ ? closeButtonParent_ : closeBtn.superview;
            return titlebar.frame.size.height;
        }

        // Blur effect
        bool setBlurEffect(BlurMode mode) {
            static Class visualEffectViewClass = NSClassFromString(@"NSVisualEffectView");
            if (!visualEffectViewClass)
                return false;

            NSVisualEffectView *effectView = nil;
            for (NSView *subview in [[nsview superview] subviews]) {
                if ([subview isKindOfClass:visualEffectViewClass]) {
                    effectView = reinterpret_cast<NSVisualEffectView *>(subview);
                }
            }
            if (effectView == nil) {
                return false;
            }

            static const auto originalMaterial = effectView.material;
            static const auto originalBlendingMode = effectView.blendingMode;
            static const auto originalState = effectView.state;

            if (mode == BlurMode::None) {
                effectView.material = originalMaterial;
                effectView.blendingMode = originalBlendingMode;
                effectView.state = originalState;
                effectView.appearance = nil;
            } else {
                effectView.material = NSVisualEffectMaterialUnderWindowBackground;
                effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
                effectView.state = NSVisualEffectStateFollowsWindowActiveState;

                if (mode == BlurMode::Dark) {
                    effectView.appearance =
                        [NSAppearance appearanceNamed:@"NSAppearanceNameVibrantDark"];
                } else {
                    effectView.appearance =
                        [NSAppearance appearanceNamed:@"NSAppearanceNameVibrantLight"];
                }
            }
            return true;
        }

        // 自绘窗口阴影时显式关闭系统阴影，避免两层阴影及透明客户区的黑边。
        void setWindowShadowEnabled(bool enabled) {
            windowShadowEnabled = enabled;
            auto window = [nsview window];
            window.hasShadow = enabled;
            if (!enabled) {
                window.opaque = NO;
                window.backgroundColor = [NSColor clearColor];
            }
            [window invalidateShadow];
        }

        // System title bar
        void setSystemTitleBarVisible(const bool visible) {
            auto nswindow = [nsview window];
            if (!nswindow) {
                return;
            }

            nsview.wantsLayer = YES;
            nswindow.styleMask |= NSWindowStyleMaskResizable;
            if (visible) {
                nswindow.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
            } else {
                nswindow.styleMask |= NSWindowStyleMaskFullSizeContentView;
            }
            nswindow.titlebarAppearsTransparent = (visible ? NO : YES);
            nswindow.titleVisibility = (visible || (nswindow.styleMask & NSWindowStyleMaskFullScreen) ? NSWindowTitleVisible : NSWindowTitleHidden);
            nswindow.hasShadow = windowShadowEnabled;
            // nswindow.showsToolbarButton = NO;
            nswindow.movableByWindowBackground = NO;
            // 命中范围由代理控制，但 AppKit 的原生拖动仍要求窗口允许移动。
            nswindow.movable = YES;
            setSystemButtonVisible(systemButtonVisible);
        }

        static void replaceImplementations() {
            // 本地事件入口早于 Qt Quick 的延迟投递；只消费标题栏空白区域的按下。
            nativeDragMonitor_ = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                handler:^NSEvent *(NSEvent *event) {
                    auto proxy = g_proxyList->value(reinterpret_cast<WId>(event.window.contentView));
                    return proxy && proxy->handleNativeDrag(event) ? nil : event;
                }];
            Method method = class_getInstanceMethod(windowClass, @selector(setStyleMask:));
            oldSetStyleMask = reinterpret_cast<setStyleMaskPtr>(
                method_setImplementation(method, reinterpret_cast<IMP>(setStyleMask)));

            method =
                class_getInstanceMethod(windowClass, @selector(setTitlebarAppearsTransparent:));
            oldSetTitlebarAppearsTransparent =
                reinterpret_cast<setTitlebarAppearsTransparentPtr>(method_setImplementation(
                    method, reinterpret_cast<IMP>(setTitlebarAppearsTransparent)));

#if 0
            method = class_getInstanceMethod(windowClass, @selector(canBecomeKeyWindow));
            oldCanBecomeKeyWindow = reinterpret_cast<canBecomeKeyWindowPtr>(method_setImplementation(method, reinterpret_cast<IMP>(canBecomeKeyWindow)));

            method = class_getInstanceMethod(windowClass, @selector(canBecomeMainWindow));
            oldCanBecomeMainWindow = reinterpret_cast<canBecomeMainWindowPtr>(method_setImplementation(method, reinterpret_cast<IMP>(canBecomeMainWindow)));
#endif

            method = class_getInstanceMethod(windowClass, @selector(sendEvent:));
            oldSendEvent = reinterpret_cast<sendEventPtr>(
                method_setImplementation(method, reinterpret_cast<IMP>(sendEvent)));

            // Alloc
            windowObserver = [[QWK_NSWindowObserver alloc] init];
        }

        static void restoreImplementations() {
            if (nativeDragMonitor_) {
                [NSEvent removeMonitor:nativeDragMonitor_];
                nativeDragMonitor_ = nil;
            }
            Method method = class_getInstanceMethod(windowClass, @selector(setStyleMask:));
            method_setImplementation(method, reinterpret_cast<IMP>(oldSetStyleMask));
            oldSetStyleMask = nil;

            method =
                class_getInstanceMethod(windowClass, @selector(setTitlebarAppearsTransparent:));
            method_setImplementation(method,
                                     reinterpret_cast<IMP>(oldSetTitlebarAppearsTransparent));
            oldSetTitlebarAppearsTransparent = nil;

#if 0
            method = class_getInstanceMethod(windowClass, @selector(canBecomeKeyWindow));
            method_setImplementation(method, reinterpret_cast<IMP>(oldCanBecomeKeyWindow));
            oldCanBecomeKeyWindow = nil;

            method = class_getInstanceMethod(windowClass, @selector(canBecomeMainWindow));
            method_setImplementation(method, reinterpret_cast<IMP>(oldCanBecomeMainWindow));
            oldCanBecomeMainWindow = nil;
#endif

            method = class_getInstanceMethod(windowClass, @selector(sendEvent:));
            method_setImplementation(method, reinterpret_cast<IMP>(oldSendEvent));
            oldSendEvent = nil;

            // Delete
            [windowObserver release];
            windowObserver = nil;
        }

        static inline const Class windowClass = [NSWindow class];

    protected:
        static BOOL canBecomeKeyWindow(id obj, SEL sel) {
            auto nswindow = reinterpret_cast<NSWindow *>(obj);
            auto nsview = [nswindow contentView];
            if (g_proxyList->contains(reinterpret_cast<WId>(nsview))) {
                return YES;
            }

            if (oldCanBecomeKeyWindow) {
                return oldCanBecomeKeyWindow(obj, sel);
            }

            return YES;
        }

        static BOOL canBecomeMainWindow(id obj, SEL sel) {
            auto nswindow = reinterpret_cast<NSWindow *>(obj);
            auto nsview = [nswindow contentView];
            if (g_proxyList->contains(reinterpret_cast<WId>(nsview))) {
                return YES;
            }

            if (oldCanBecomeMainWindow) {
                return oldCanBecomeMainWindow(obj, sel);
            }

            return YES;
        }

        static void setStyleMask(id obj, SEL sel, NSWindowStyleMask styleMask) {
            auto nswindow = reinterpret_cast<NSWindow *>(obj);
            auto nsview = [nswindow contentView];
            if (g_proxyList->contains(reinterpret_cast<WId>(nsview))) {
                styleMask |= NSWindowStyleMaskFullSizeContentView;
            }

            if (oldSetStyleMask) {
                oldSetStyleMask(obj, sel, styleMask);
            }
        }

        static void setTitlebarAppearsTransparent(id obj, SEL sel, BOOL transparent) {
            auto nswindow = reinterpret_cast<NSWindow *>(obj);
            auto nsview = [nswindow contentView];
            if (g_proxyList->contains(reinterpret_cast<WId>(nsview))) {
                transparent = YES;
            }

            if (oldSetTitlebarAppearsTransparent) {
                oldSetTitlebarAppearsTransparent(obj, sel, transparent);
            }
        }

        static void sendEvent(id obj, SEL sel, NSEvent *event) {
            if (oldSendEvent) {
                oldSendEvent(obj, sel, event);
            }

#if 0
            const auto nswindow = reinterpret_cast<NSWindow *>(obj);
            const auto it = instances.find(nswindow);
            if (it == instances.end()) {
                return;
            }

            NSWindowProxy *proxy = it.value();
            if (event.type == NSEventTypeLeftMouseDown) {
                proxy->lastMouseDownEvent = event;
                QCoreApplication::processEvents();
                proxy->lastMouseDownEvent = nil;
            }
#endif
        }

    private:
        Q_DISABLE_COPY(NSWindowProxy)

        NSView *nsview = nil;
        NSButton *hostedCloseButton_ = nil;
        NSView *closeButtonParent_ = nil;
        QWK_SystemButtonHost *closeButtonHost_ = nil;
        NSRect closeButtonOriginalFrame_ = NSZeroRect;
        std::function<bool(const QPoint &)> titleBarHitTest_;
        std::function<void()> titleBarDoubleClick_;
        QWK_NSViewObserver* observer = nil;

        bool systemButtonVisible = true;
        bool windowShadowEnabled = true;
        bool closeButtonOnly = false;
        ScreenRectCallback screenRectCallback;

        static inline QWK_NSWindowObserver *windowObserver = nil;
        static inline id nativeDragMonitor_ = nil;

        // NSEvent *lastMouseDownEvent = nil;

        using setStyleMaskPtr = void (*)(id, SEL, NSWindowStyleMask);
        static inline setStyleMaskPtr oldSetStyleMask = nil;

        using setTitlebarAppearsTransparentPtr = void (*)(id, SEL, BOOL);
        static inline setTitlebarAppearsTransparentPtr oldSetTitlebarAppearsTransparent = nil;

        using canBecomeKeyWindowPtr = BOOL (*)(id, SEL);
        static inline canBecomeKeyWindowPtr oldCanBecomeKeyWindow = nil;

        using canBecomeMainWindowPtr = BOOL (*)(id, SEL);
        static inline canBecomeMainWindowPtr oldCanBecomeMainWindow = nil;

        using sendEventPtr = void (*)(id, SEL, NSEvent *);
        static inline sendEventPtr oldSendEvent = nil;
    };

    static inline NSWindow *mac_getNSWindow(const WId windowId) {
        const auto nsview = reinterpret_cast<NSView *>(windowId);
        return [nsview window];
    }

    static inline NSWindowProxy *ensureWindowProxy(const WId windowId) {
        if (g_proxyList->isEmpty()) {
            NSWindowProxy::replaceImplementations();
        }

        auto it = g_proxyList->find(windowId);
        if (it == g_proxyList->end()) {
            NSView *nsview = reinterpret_cast<NSView *>(windowId);
            const auto proxy = new NSWindowProxy(nsview);
            it = g_proxyList->insert(windowId, proxy);
        }
        return it.value();
    }

    static inline void releaseWindowProxy(const WId windowId) {
        if (auto proxy = g_proxyList->take(windowId)) {
            // TODO: Determine if the window is valid

            // The window has been destroyed
            // proxy->setSystemTitleBarVisible(true);
            delete proxy;
        } else {
            return;
        }

        if (g_proxyList->isEmpty()) {
            NSWindowProxy::restoreImplementations();
        }
    }

    class CocoaWindowEventFilter : public SharedEventFilter {
    public:
        explicit CocoaWindowEventFilter(AbstractWindowContext *context);
        ~CocoaWindowEventFilter() override;

        enum WindowStatus {
            Idle,
            WaitingRelease,
            PreparingMove,
            Moving,
        };

    protected:
        bool sharedEventFilter(QObject *object, QEvent *event) override;

    private:
        AbstractWindowContext *m_context;
        bool m_cursorShapeChanged;
        WindowStatus m_windowStatus;
    };

    CocoaWindowEventFilter::CocoaWindowEventFilter(AbstractWindowContext *context)
        : m_context(context), m_cursorShapeChanged(false), m_windowStatus(Idle) {
        m_context->installSharedEventFilter(this);
    }

    CocoaWindowEventFilter::~CocoaWindowEventFilter() = default;

    bool CocoaWindowEventFilter::sharedEventFilter(QObject *obj, QEvent *event) {
        Q_UNUSED(obj)

        auto type = event->type();
        if (type < QEvent::MouseButtonPress || type > QEvent::MouseMove) {
            return false;
        }
        auto host = m_context->host();
        auto window = m_context->window();
        auto delegate = m_context->delegate();
        auto me = static_cast<const QMouseEvent *>(event);

        QPoint scenePos = getMouseEventScenePos(me);
        QPoint globalPos = getMouseEventGlobalPos(me);

        bool inTitleBar = m_context->isInTitleBarDraggableArea(scenePos);
        switch (type) {
            case QEvent::MouseButtonPress: {
                switch (me->button()) {
                    case Qt::LeftButton: {
                        if (inTitleBar) {
                            // 原生事件由本地 monitor 接管；此处保留 Qt 合成事件的兼容路径。
                            m_windowStatus = PreparingMove;
                            event->accept();
                            return true;
                        }
                        break;
                    }
                    case Qt::RightButton: {
                        m_context->showSystemMenu(globalPos);
                        break;
                    }
                    default:
                        break;
                }
                m_windowStatus = WaitingRelease;
                break;
            }

            case QEvent::MouseButtonRelease: {
                switch (m_windowStatus) {
                    case PreparingMove:
                    case Moving: {
                        m_windowStatus = Idle;
                        event->accept();
                        return true;
                    }
                    case WaitingRelease: {
                        m_windowStatus = Idle;
                        break;
                    }
                    default: {
                        if (inTitleBar) {
                            event->accept();
                            return true;
                        }
                        break;
                    }
                }
                break;
            }

            case QEvent::MouseMove: {
                // 系统拖动可能消耗 release；无按键的移动必须清除旧状态，不能吞掉后续悬停。
                if (!(me->buttons() & Qt::LeftButton)) {
                    m_windowStatus = Idle;
                    break;
                }
                switch (m_windowStatus) {
                    case Moving: {
                        return true;
                    }
                    case PreparingMove: {
#if QT_VERSION >= QT_VERSION_CHECK(5, 15, 0)
                        // 触摸板事件尚未具备有效原生拖动事件时，下次移动继续尝试。
                        m_windowStatus = window->startSystemMove() ? Moving : PreparingMove;
#else
                        startSystemMove(window);
                        m_windowStatus = Moving;
#endif
                        event->accept();
                        return true;
                    }
                    default:
                        break;
                }
                break;
            }

            case QEvent::MouseButtonDblClick: {
                if (me->button() == Qt::LeftButton && inTitleBar && !m_context->isHostSizeFixed()) {
                    Qt::WindowFlags windowFlags = delegate->getWindowFlags(host);
                    Qt::WindowStates windowState = delegate->getWindowState(host);
                    if (!(windowState & Qt::WindowFullScreen)) {
                        if (windowState & Qt::WindowMaximized) {
                            delegate->setWindowState(host, windowState & ~Qt::WindowMaximized);
                        } else {
                            delegate->setWindowState(host, windowState | Qt::WindowMaximized);
                        }
                        event->accept();
                        return true;
                    }
                }
                break;
            }

            default:
                break;
        }
        return false;
    }

    CocoaWindowContext::CocoaWindowContext() : AbstractWindowContext() {
        cocoaWindowEventFilter = std::make_unique<CocoaWindowEventFilter>(this);
    }

    CocoaWindowContext::~CocoaWindowContext() {
        releaseWindowProxy(m_windowId);
    }

    QString CocoaWindowContext::key() const {
        return QStringLiteral("cocoa");
    }

    void CocoaWindowContext::virtual_hook(int id, void *data) {
        switch (id) {
            case SystemButtonAreaChangedHook: {
                ensureWindowProxy(m_windowId)->setScreenRectCallback(m_systemButtonAreaCallback);
                return;
            }

            default:
                break;
        }
        AbstractWindowContext::virtual_hook(id, data);
    }

    QVariant CocoaWindowContext::windowAttribute(const QString &key) const {
        if (key == QStringLiteral("title-bar-height")) {
            if (!m_windowId)
                return {};
            return ensureWindowProxy(m_windowId)->titleBarHeight();
        }
        return AbstractWindowContext::windowAttribute(key);
    }

    void CocoaWindowContext::winIdChanged(WId winId, WId oldWinId) {
        // If the original window id is valid, remove all resources related
        if (oldWinId) {
            releaseWindowProxy(oldWinId);
        }

        if (!winId) {
            return;
        }

        // Allocate new resources
        const auto proxy = ensureWindowProxy(winId);
        if (proxy) {
            proxy->setTitleBarHitTest([this](const QPoint &point) {
                return isInTitleBarDraggableArea(point);
            }, [this]() {
                if (isHostSizeFixed())
                    return;
                const auto state = delegate()->getWindowState(host());
                if (!(state & Qt::WindowFullScreen))
                    delegate()->setWindowState(host(), state ^ Qt::WindowMaximized);
            });
            proxy->setCloseButtonOnly(windowAttribute(QStringLiteral("close-button-only")).toBool());
            proxy->setSystemButtonVisible(!windowAttribute(QStringLiteral("no-system-buttons")).toBool());
            proxy->setScreenRectCallback(m_systemButtonAreaCallback);
            proxy->setWindowShadowEnabled(!windowAttribute(QStringLiteral("no-window-shadow")).toBool());
            proxy->setSystemTitleBarVisible(false);
        }
    }

    bool CocoaWindowContext::windowAttributeChanged(const QString &key, const QVariant &attribute,
                                                    const QVariant &oldAttribute) {
        Q_UNUSED(oldAttribute)

        Q_ASSERT(m_windowId);

        if (key == QStringLiteral("close-button-only")) {
            if (attribute.userType() != QMetaType::Bool)
                return false;
            const auto proxy = ensureWindowProxy(m_windowId);
            proxy->setCloseButtonOnly(attribute.toBool());
            return true;
        }

        if (key == QStringLiteral("no-window-shadow")) {
            if (attribute.userType() != QMetaType::Bool)
                return false;
            ensureWindowProxy(m_windowId)->setWindowShadowEnabled(!attribute.toBool());
            return true;
        }

        if (key == QStringLiteral("no-system-buttons")) {
#if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
            if (attribute.type() != QVariant::Bool)
#else
            if (attribute.typeId() != QMetaType::Type::Bool)
#endif
                return false;
            ensureWindowProxy(m_windowId)->setSystemButtonVisible(!attribute.toBool());
            return true;
        }

        if (key == QStringLiteral("blur-effect")) {
            auto mode = NSWindowProxy::BlurMode::None;
#if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
            if (attribute.type() == QVariant::Bool) {
#else
            if (attribute.typeId() == QMetaType::Type::Bool) {
#endif
                if (attribute.toBool()) {
                    NSString *osxMode =
                        [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
                    mode = [osxMode isEqualToString:@"Dark"] ? NSWindowProxy::BlurMode::Dark
                                                             : NSWindowProxy::BlurMode::Light;
                }
#if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
            } else if (attribute.type() == QVariant::String) {
#else
            } else if (attribute.typeId() == QMetaType::Type::QString) {
#endif
                auto value = attribute.toString();
                if (value == QStringLiteral("dark")) {
                    mode = NSWindowProxy::BlurMode::Dark;
                } else if (value == QStringLiteral("light")) {
                    mode = NSWindowProxy::BlurMode::Light;
                } else if (value == QStringLiteral("none")) {
                    // ...
                } else {
                    return false;
                }
            } else {
                return false;
            }
            return ensureWindowProxy(m_windowId)->setBlurEffect(mode);
        }
        return false;
    }

}

@implementation QWK_NSViewObserver {
    QWK::NSWindowProxy* _proxy; // Weak reference
}

- (instancetype)initWithProxy:(QWK::NSWindowProxy*)proxy {
    if (self = [super init]) {
        _proxy = proxy;
    }
    return self;
}

// Using QEvent::Show to call setSystemTitleBarVisible/updateSystemButtonRect could also work,
// but observing the window property change via KVO provides more immediate notification when
// the NSWindow becomes available, making this approach more natural and reliable.
- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
    if ([keyPath isEqualToString:@"window"]) {
        NSWindow* newWindow = change[NSKeyValueChangeNewKey];
        // NSWindow* oldWindow = change[NSKeyValueChangeOldKey];
        if (newWindow) {
            _proxy->setSystemTitleBarVisible(false);
            _proxy->updateSystemButtonRect();
        }
    }
}

@end
