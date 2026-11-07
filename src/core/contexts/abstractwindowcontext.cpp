// Copyright (C) 2021-2023 wangwenx190 (Yuhang Zhao)
// Copyright (C) 2023-2024 Stdware Collections (https://www.github.com/stdware)
// SPDX-License-Identifier: Apache-2.0

#include "abstractwindowcontext_p.h"

#include <QtGui/QPen>
#include <QtGui/QPainter>
#include <QtGui/QScreen>
#include <QtGui/QMouseEvent>
#include <QtGui/QGuiApplication>
#include <algorithm>
#include <cmath>

#include "qwkglobal_p.h"

namespace QWK {

    AbstractWindowContext::AbstractWindowContext() = default;

    AbstractWindowContext::~AbstractWindowContext() = default;

    void AbstractWindowContext::setup(QObject *host, WindowItemDelegate *delegate) {
        if (m_host || !host || !delegate) {
            return;
        }
        m_host = host;
        m_delegate.reset(delegate);
        m_winIdChangeEventFilter.reset(delegate->createWinIdEventFilter(host, this));
        notifyWinIdChange();
    }

    bool AbstractWindowContext::setHitTestVisible(QObject *obj, bool visible) {
        Q_ASSERT(obj);
        if (!obj) {
            return false;
        }

        if (visible) {
            m_hitTestVisibleItems.removeAll(nullptr);
            m_hitTestVisibleItems.removeAll(obj);
            m_hitTestVisibleItems.append(obj);
        } else {
            for (auto &item : m_hitTestVisibleItems) {
                if (item == obj) {
                    item = nullptr;
                }
            }
        }
        return true;
    }

    bool AbstractWindowContext::setSystemButton(WindowAgentBase::SystemButton button,
                                                QObject *obj) {
        Q_ASSERT(button != WindowAgentBase::Unknown);
        if (button == WindowAgentBase::Unknown) {
            return false;
        }

        auto org = m_systemButtons[button];
        if (org == obj) {
            return false;
        }
        m_systemButtons[button] = obj;
        return true;
    }

    bool AbstractWindowContext::setTitleBar(QObject *item) {
        Q_ASSERT(item);
        auto org = m_titleBar;
        if (org == item) {
            return false;
        }

        if (org) {
            // Since the title bar is changed, all items inside it should be dereferenced right away
            removeSystemButtonsAndHitTestItems();
        }
        m_titleBar = item;
        return true;
    }

#ifdef Q_OS_MAC
    void AbstractWindowContext::setSystemButtonAreaCallback(const ScreenRectCallback &callback) {
        m_systemButtonAreaCallback = callback;
        virtual_hook(SystemButtonAreaChangedHook, nullptr);
    }
#endif

    bool AbstractWindowContext::isInSystemButtons(const QPoint &pos,
                                                  WindowAgentBase::SystemButton *button) const {
        *button = WindowAgentBase::Unknown;
        for (int i = WindowAgentBase::WindowIcon; i <= WindowAgentBase::Close; ++i) {
            auto currentButton = m_systemButtons[i];
            if (!currentButton || !m_delegate->isVisible(currentButton) || !m_delegate->isEnabled(currentButton)) {
                continue;
            }
            if (m_delegate->mapGeometryToScene(currentButton).contains(pos)) {
                *button = static_cast<WindowAgentBase::SystemButton>(i);
                return true;
            }
        }
        return false;
    }

    bool AbstractWindowContext::isInTitleBarDraggableArea(const QPoint &pos) const {
        if (resizeMargin() > 0 && resizeEdgesAt(pos))
            return false;
        if (!m_titleBar) {
            // There's no title bar at all, the mouse will always be in the client area.
            return false;
        }
        if (!m_delegate->isVisible(m_titleBar) || !m_delegate->isEnabled(m_titleBar)) {
            // The title bar is hidden or disabled for some reason, treat it as there's
            // no title bar.
            return false;
        }
        QRect windowRect = {QPoint(0, 0), m_windowHandle->size()};
        QRect titleBarRect = m_delegate->mapGeometryToScene(m_titleBar);
        if (!titleBarRect.intersects(windowRect)) {
            // The title bar is totally outside the window for some reason,
            // also treat it as there's no title bar.
            return false;
        }

        if (!titleBarRect.contains(pos)) {
            return false;
        }

        WindowAgentBase::SystemButton button;
        if (isInSystemButtons(pos, &button)) {
            return false;
        }

        for (auto &&item : std::as_const(m_hitTestVisibleItems)) {
            if (item && m_delegate->isVisible(item) &&
                m_delegate->mapGeometryToScene(item).contains(pos)) {
                return false;
            }
        }
        return true;
    }

    QString AbstractWindowContext::key() const {
        return {};
    }

    QWK_USED static constexpr const struct {
        const quint32 activeLight = MAKE_RGBA_COLOR(210, 233, 189, 226);
        const quint32 activeDark = MAKE_RGBA_COLOR(177, 205, 190, 240);
        const quint32 inactiveLight = MAKE_RGBA_COLOR(193, 195, 211, 203);
        const quint32 inactiveDark = MAKE_RGBA_COLOR(240, 240, 250, 255);
    } kSampleColorSet;

    void AbstractWindowContext::virtual_hook(int id, void *data) {
        switch (id) {
            case CentralizeHook: {
                if (!m_windowId)
                    return;

                QRect windowGeometry = m_delegate->getGeometry(m_host);
                QRect screenGeometry = m_windowHandle->screen()->geometry();
                int x = (screenGeometry.width() - windowGeometry.width()) / 2;
                int y = (screenGeometry.height() - windowGeometry.height()) / 2;
                QPoint pos(x, y);
                pos += screenGeometry.topLeft();
                m_delegate->setGeometry(m_host, QRect(pos, windowGeometry.size()));
                return;
            }

            case RaiseWindowHook: {
                if (!m_windowId)
                    return;

                m_delegate->setWindowVisible(m_host, true);
                Qt::WindowStates state = m_delegate->getWindowState(m_host);
                if (state & Qt::WindowMinimized) {
                    m_delegate->setWindowState(m_host, state & ~Qt::WindowMinimized);
                }
                m_delegate->bringWindowToTop(m_host);
                return;
            }

            case DefaultColorsHook: {
                auto &map = *static_cast<QMap<QString, QColor> *>(data);
                map.clear();
                map.insert(QStringLiteral("activeLight"), kSampleColorSet.activeLight);
                map.insert(QStringLiteral("activeDark"), kSampleColorSet.activeDark);
                map.insert(QStringLiteral("inactiveLight"), kSampleColorSet.inactiveLight);
                map.insert(QStringLiteral("inactiveDark"), kSampleColorSet.inactiveDark);
                return;
            }

            default:
                break;
        }
    }

    void AbstractWindowContext::showSystemMenu(const QPoint &pos) {
        virtual_hook(ShowSystemMenuHook, &const_cast<QPoint &>(pos));
    }

    void AbstractWindowContext::notifyWinIdChange() {
        auto oldWinId = m_windowId;
        m_windowId = m_winIdChangeEventFilter->winId();

        // In Qt6, after QWidget::close() is called, the related QWindow's all surfaces and the
        // platform window will be removed, and the WinId will be set to 0. After that, when the
        // QWidget is shown again, the whole things will be recreated again.
        // As a result, we must update our WindowContext each time the WinId changes.
        if (m_windowHandle) {
            removeEventFilter(m_windowHandle);
        }
        m_windowHandle = m_delegate->hostWindow(m_host);
        if (m_windowHandle) {
            m_windowHandle->installEventFilter(this);
        }

        if (oldWinId != m_windowId) {
            winIdChanged(m_windowId, oldWinId);

            if (m_windowId) {
                // Refresh window attributes
                for (auto it = m_windowAttributesOrder.begin();
                     it != m_windowAttributesOrder.end();) {
                    if (!windowAttributeChanged(it->first, it->second, {})) {
                        m_windowAttributes.remove(it->first);
                        it = m_windowAttributesOrder.erase(it);
                        continue;
                    }
                    ++it;
                }
            }

            // Send to shared dispatchers
            QEvent e(QEvent::WinIdChange);
            sharedDispatch(m_host, &e);
        }
    }

    QVariant AbstractWindowContext::windowAttribute(const QString &key) const {
        auto it = m_windowAttributes.find(key);
        if (it == m_windowAttributes.end()) {
            return {};
        }
        return it.value()->second;
    }

    bool AbstractWindowContext::setWindowAttribute(const QString &key, const QVariant &attribute) {
        auto it = m_windowAttributes.find(key);
        if (it == m_windowAttributes.end()) {
            if (!attribute.isValid()) {
                return true;
            }
            if (m_windowId && !windowAttributeChanged(key, attribute, {})) {
                return false;
            }
            m_windowAttributes.insert(
                key, m_windowAttributesOrder.insert(m_windowAttributesOrder.end(),
                                                    std::make_pair(key, attribute)));
            return true;
        }

        auto &listIter = it.value();
        auto &oldAttr = listIter->second;
        if (m_windowId && !windowAttributeChanged(key, attribute, oldAttr)) {
            return false;
        }

        if (attribute.isValid()) {
            oldAttr = attribute;
            m_windowAttributesOrder.splice(m_windowAttributesOrder.end(), m_windowAttributesOrder,
                                           listIter);
        } else {
            m_windowAttributesOrder.erase(listIter);
            m_windowAttributes.erase(it);
        }
        return true;
    }

    qreal AbstractWindowContext::resizeMargin() const {
        return windowAttribute(QStringLiteral("resize-margin")).toReal();
    }

    Qt::Edges AbstractWindowContext::resizeEdgesAt(const QPoint &pos) const {
        if (!m_windowHandle || m_windowHandle->visibility() != QWindow::Windowed
            || isHostSizeFixed())
            return {};
        const qreal margin = resizeMargin();
        const QRectF surface(margin, margin, m_windowHandle->width() - 2 * margin,
                             m_windowHandle->height() - 2 * margin);
        // 保留既有8px命中宽度，在可见边框内外各分配一半。
        constexpr qreal halfBorder = 4;
        if (surface.isEmpty() || !surface.adjusted(-halfBorder, -halfBorder,
                                                    halfBorder, halfBorder).contains(pos))
            return {};
        Qt::Edges edges;
        if (!isHostWidthFixed()) {
            if (std::abs(pos.x() - surface.left()) <= halfBorder) edges |= Qt::LeftEdge;
            else if (std::abs(pos.x() - surface.right()) <= halfBorder) edges |= Qt::RightEdge;
        }
        if (!isHostHeightFixed()) {
            if (std::abs(pos.y() - surface.top()) <= halfBorder) edges |= Qt::TopEdge;
            else if (std::abs(pos.y() - surface.bottom()) <= halfBorder) edges |= Qt::BottomEdge;
        }
        return edges;
    }

    void AbstractWindowContext::resetCustomResize() {
        resizeEdges_ = {};
        const bool grabbed = std::exchange(resizeMouseGrabbed_, false);
        if (m_windowHandle && grabbed) m_windowHandle->setMouseGrabEnabled(false);
        if (std::exchange(resizeCursorChanged_, false) && m_windowHandle)
            m_delegate->restoreCursorShape(m_host);
    }

    bool AbstractWindowContext::handleCustomResizeEvent(QEvent *event) {
        if (resizeMargin() <= 0) return false;
        const auto type = event->type();
        if (type == QEvent::Hide || type == QEvent::WindowDeactivate
            || type == QEvent::WindowStateChange || type == QEvent::UngrabMouse) {
            resetCustomResize();
            return false;
        }
        if (type != QEvent::MouseMove && type != QEvent::MouseButtonPress
            && type != QEvent::MouseButtonRelease)
            return false;
        auto *mouse = static_cast<QMouseEvent *>(event);
        const auto window = m_windowHandle;
        if (type == QEvent::MouseButtonRelease && mouse->button() == Qt::LeftButton
            && resizeEdges_) {
            resetCustomResize();
            event->accept();
            return true;
        }
        if (type == QEvent::MouseMove && resizeEdges_) {
            if (!(mouse->buttons() & Qt::LeftButton)) {
                resetCustomResize();
                return false;
            }
            const QPoint delta = getMouseEventGlobalPos(mouse) - resizeStartPosition_;
            QRect geometry = resizeStartGeometry_;
            const int minWidth = std::max(1, window->minimumWidth());
            const int minHeight = std::max(1, window->minimumHeight());
            const int maxWidth = std::max(minWidth, window->maximumWidth());
            const int maxHeight = std::max(minHeight, window->maximumHeight());
            if (resizeEdges_.testFlag(Qt::LeftEdge)) {
                const int width = std::clamp(geometry.width() - delta.x(), minWidth, maxWidth);
                geometry.setLeft(geometry.right() + 1 - width);
            } else if (resizeEdges_.testFlag(Qt::RightEdge)) {
                geometry.setWidth(std::clamp(geometry.width() + delta.x(), minWidth, maxWidth));
            }
            if (resizeEdges_.testFlag(Qt::TopEdge)) {
                const int height = std::clamp(geometry.height() - delta.y(), minHeight, maxHeight);
                geometry.setTop(geometry.bottom() + 1 - height);
            } else if (resizeEdges_.testFlag(Qt::BottomEdge)) {
                geometry.setHeight(std::clamp(geometry.height() + delta.y(), minHeight, maxHeight));
            }
            window->setGeometry(geometry);
            event->accept();
            return true;
        }
        const Qt::Edges edges = resizeEdgesAt(getMouseEventScenePos(mouse));
        if (type == QEvent::MouseMove && mouse->buttons() == Qt::NoButton) {
            if (!edges) {
                if (std::exchange(resizeCursorChanged_, false))
                    m_delegate->restoreCursorShape(m_host);
                return false;
            }
            const bool horizontal = edges.testFlag(Qt::LeftEdge) || edges.testFlag(Qt::RightEdge);
            const bool vertical = edges.testFlag(Qt::TopEdge) || edges.testFlag(Qt::BottomEdge);
            const bool forward = (edges.testFlag(Qt::LeftEdge) && edges.testFlag(Qt::TopEdge))
                              || (edges.testFlag(Qt::RightEdge) && edges.testFlag(Qt::BottomEdge));
            m_delegate->setCursorShape(m_host, horizontal && vertical
                ? (forward ? Qt::SizeFDiagCursor : Qt::SizeBDiagCursor)
                : horizontal ? Qt::SizeHorCursor : Qt::SizeVerCursor);
            resizeCursorChanged_ = true;
            event->accept();
            return true;
        }
        if (type != QEvent::MouseButtonPress || mouse->button() != Qt::LeftButton || !edges)
            return false;
#if QT_VERSION >= QT_VERSION_CHECK(5, 15, 0)
        if (window->startSystemResize(edges)) {
            event->accept();
            return true;
        }
#endif
        // Cocoa缺少系统resize入口；使用同一逻辑坐标和尺寸约束回退。
        // Wayland不允许任意设置顶层位置，系统拒绝时明确报告，不能假装成功。
        if (QGuiApplication::platformName().startsWith(QStringLiteral("wayland"))) {
            qWarning() << "QWindowKit: compositor rejected resizing at the visible window border";
            return false;
        }
        resizeEdges_ = edges;
        resizeStartPosition_ = getMouseEventGlobalPos(mouse);
        resizeStartGeometry_ = window->geometry();
        resizeMouseGrabbed_ = window->setMouseGrabEnabled(true);
        event->accept();
        return true;
    }

    bool AbstractWindowContext::eventFilter(QObject *obj, QEvent *event) {
        if (obj == m_windowHandle
            && (handleCustomResizeEvent(event) || sharedDispatch(obj, event))) {
            return true;
        }
        return QObject::eventFilter(obj, event);
    }

    bool AbstractWindowContext::windowAttributeChanged(const QString &key,
                                                       const QVariant &attribute,
                                                       const QVariant &oldAttribute) {
        if (key == QStringLiteral("resize-margin")) {
            bool valid = false;
            const qreal margin = attribute.toDouble(&valid);
            if (!valid || !std::isfinite(margin) || margin < 0) return false;
            resetCustomResize();
            return true;
        }
        return false;
    }

    void AbstractWindowContext::removeSystemButtonsAndHitTestItems() {
        for (auto &button : m_systemButtons) {
            if (!button) {
                continue;
            }
            button = nullptr;
        }
        m_hitTestVisibleItems.clear();
    }

}
