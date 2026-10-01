// Copyright (C) 2023-2024 Stdware Collections (https://www.github.com/stdware)
// Copyright (C) 2021-2023 wangwenx190 (Yuhang Zhao)
// SPDX-License-Identifier: Apache-2.0

#include "quickwindowagent_p.h"
#include <QTimer>
#include <QQuickWindow>

namespace QWK {

    class SystemButtonAreaItemHandler : public QObject {
    public:
        SystemButtonAreaItemHandler(QQuickItem *item, AbstractWindowContext *ctx,
                                    QObject *parent = nullptr);
        ~SystemButtonAreaItemHandler() override = default;

        void updateSystemButtonArea();
        void trackAncestors();

    protected:
        QQuickItem *item;
        AbstractWindowContext *ctx;
        QList<QMetaObject::Connection> ancestorConnections_;
        bool updatePending_ = false;
    };

    SystemButtonAreaItemHandler::SystemButtonAreaItemHandler(QQuickItem *item,
                                                             AbstractWindowContext *ctx,
                                                             QObject *parent)
        : QObject(parent), item(item), ctx(ctx) {
        connect(item, &QQuickItem::xChanged, this,
                &SystemButtonAreaItemHandler::updateSystemButtonArea);
        connect(item, &QQuickItem::yChanged, this,
                &SystemButtonAreaItemHandler::updateSystemButtonArea);
        connect(item, &QQuickItem::widthChanged, this,
                &SystemButtonAreaItemHandler::updateSystemButtonArea);
        connect(item, &QQuickItem::heightChanged, this,
                &SystemButtonAreaItemHandler::updateSystemButtonArea);
        connect(item, &QQuickItem::visibleChanged, this,
                &SystemButtonAreaItemHandler::updateSystemButtonArea);
        connect(item, &QQuickItem::parentChanged, this,
                &SystemButtonAreaItemHandler::trackAncestors);
        trackAncestors();

        ctx->setSystemButtonAreaCallback([item](const QSize &nativeSize) {
            // Qt 全局缩放下，场景逻辑坐标与 AppKit 的视图坐标并不相同。
            const auto window = item->window();
            const qreal scale = window && window->width() > 0
                ? qreal(nativeSize.width()) / window->width() : 1.0;
            const QRectF nativeRect(item->mapToScene(QPointF(0, 0)) * scale,
                                    item->size() * scale);
            // 整数 QRect 保留半像素中心，避免独立取整边界后把交通灯偏移一像素。
            const QPoint doubledCenter(qRound(nativeRect.center().x() * 2),
                                       qRound(nativeRect.center().y() * 2));
            QSize size(qRound(nativeRect.width()), qRound(nativeRect.height()));
            if ((size.width() & 1) != (doubledCenter.x() & 1))
                size.rwidth() += 1;
            if ((size.height() & 1) != (doubledCenter.y() & 1))
                size.rheight() += 1;
            return QRect(QPoint((doubledCenter.x() - size.width()) / 2,
                                (doubledCenter.y() - size.height()) / 2), size);
        });
    }

    void SystemButtonAreaItemHandler::updateSystemButtonArea() {
        // 父级阴影留白和布局也会改变场景坐标；等本轮布局完成再定位原生按钮。
        if (updatePending_)
            return;
        updatePending_ = true;
        QTimer::singleShot(0, this, [this] {
            updatePending_ = false;
            ctx->virtual_hook(AbstractWindowContext::SystemButtonAreaChangedHook, nullptr);
        });
    }

    void SystemButtonAreaItemHandler::trackAncestors() {
        for (const auto &connection : ancestorConnections_)
            disconnect(connection);
        ancestorConnections_.clear();
        for (auto ancestor = item->parentItem(); ancestor; ancestor = ancestor->parentItem()) {
            ancestorConnections_.append(connect(ancestor, &QQuickItem::xChanged, this,
                &SystemButtonAreaItemHandler::updateSystemButtonArea));
            ancestorConnections_.append(connect(ancestor, &QQuickItem::yChanged, this,
                &SystemButtonAreaItemHandler::updateSystemButtonArea));
            ancestorConnections_.append(connect(ancestor, &QQuickItem::parentChanged, this,
                &SystemButtonAreaItemHandler::trackAncestors));
        }
        if (auto window = item->window())
            ancestorConnections_.append(connect(window, &QWindow::visibleChanged, this,
                &SystemButtonAreaItemHandler::updateSystemButtonArea));
        updateSystemButtonArea();
    }

    QQuickItem *QuickWindowAgent::systemButtonArea() const {
        Q_D(const QuickWindowAgent);
        return d->systemButtonAreaItem;
    }

    void QuickWindowAgent::setSystemButtonArea(QQuickItem *item) {
        Q_D(QuickWindowAgent);
        if (d->systemButtonAreaItem == item)
            return;

        auto ctx = d->context.get();
        d->systemButtonAreaItem = item;
        if (!item) {
            d->systemButtonAreaItemHandler.reset();
            ctx->setSystemButtonAreaCallback({});
            return;
        }
        d->systemButtonAreaItemHandler = std::make_unique<SystemButtonAreaItemHandler>(item, ctx);
    }

    ScreenRectCallback QuickWindowAgent::systemButtonAreaCallback() const {
        Q_D(const QuickWindowAgent);
        return d->systemButtonAreaItem ? nullptr : d->context->systemButtonAreaCallback();
    }

    void QuickWindowAgent::setSystemButtonAreaCallback(const ScreenRectCallback &callback) {
        Q_D(QuickWindowAgent);
        setSystemButtonArea(nullptr);
        d->context->setSystemButtonAreaCallback(callback);
    }

}
