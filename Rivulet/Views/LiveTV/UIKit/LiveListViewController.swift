// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveListViewController.swift
//  Rivulet
//
//  The List layout: categories on the left (`LiveCategoryList`), the chosen
//  one's channels on the right with what each airs now. Selection follows
//  focus, as in the guide's category pills. Plays and opens the programme menu
//  as What's On does; there is no corner player here, so Back ends a channel.
//  Right on a channel opens the guide for its category (`onOpenGuide`); the
//  host brings the list back on the guide's tab and channel (`LiveListReturn`).
//

import UIKit
import Combine

/// Where the list comes back to from the guide: the guide's tab, and the
/// channel focused there.
struct LiveListReturn {
    let target: LiveGuideTarget
    let channelId: String?
}

final class LiveListViewController: UIViewController {

    private enum Metrics {
        /// The Live TV pages' margin (`MediaRowMetrics.liveLeading`).
        static let side: CGFloat = MediaRowMetrics.liveLeading
        /// Below the shell's collapsed pill.
        static let top: CGFloat = ShellPillMetrics.contentClearance
        /// The clock's line, as on What's On.
        static let clockTop: CGFloat = 52
        static let categoryWidth: CGFloat = 480
        static let columnGap: CGFloat = 72
        /// The chosen category's name and count above its channels.
        static let headerHeight: CGFloat = 92
        static let channelSpacing: CGFloat = 8
        static var channelX: CGFloat { side + categoryWidth + columnGap }
    }

    private let sourceIdFilter: String?
    /// Right on a channel: the guide for the selected category, on that channel.
    var onOpenGuide: ((LiveGuideTarget, String) -> Void)?
    private var returning: LiveListReturn?
    /// The channel to focus once its row is on screen, back from the guide.
    private var restoreChannelId: String?
    /// Made to come back from the guide, which took focus away with it.
    private var claimsFocusOnAppear = false
    private var list = LiveCategoryList.build(LiveCategoryList.Input(channels: []))
    private var selectedId: String?
    /// Folded sections per sidebar entry, kept for the session: the list is
    /// rebuilt each time it comes back from the guide.
    private static var collapsedBySource: [String: Set<String>] = [:]
    private var collapsedSourceIds: Set<String> {
        get { Self.collapsedBySource[sourceIdFilter ?? ""] ?? [] }
        set { Self.collapsedBySource[sourceIdFilter ?? ""] = newValue }
    }
    /// The channels on the right, and the category they belong to.
    private var shownCategoryId: String?
    private var shownIds: [String] = []
    private var shownById: [String: UnifiedChannel] = [:]

    private let categoryView = SidebarCollectionView(
        frame: .zero, collectionViewLayout: makeLayout(rowHeight: LiveCategoryCell.height, spacing: 0, sideInset: 0))
    private let channelView = UICollectionView(
        frame: .zero, collectionViewLayout: makeLayout(rowHeight: LiveChannelRowCell.height,
                                                       spacing: Metrics.channelSpacing,
                                                       sideInset: LiveChannelRowCell.platterOutset))
    private var categoryData: UICollectionViewDiffableDataSource<Int, String>!
    private var channelData: UICollectionViewDiffableDataSource<Int, String>!
    /// Between the columns: Right lands on the channels' first visible row,
    /// Left on the selected category, rather than on the nearest row.
    private let columnGuide = UIFocusGuide()

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let clockLabel = UILabel()
    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    /// Read once by `preferredFocusEnvironments`.
    private var pendingFocus: UIFocusEnvironment?
    private var cancellables = Set<AnyCancellable>()
    private var minuteTimer: Timer?
    private var guideSwipe: DirectionalInputBinding?
    /// The remote gesture that brought focus into the channels. That same
    /// Right goes on to reach `pressesBegan`, and must not open the guide.
    private var channelEntryGesture = -1

    private static let timeFormat = Date.FormatStyle.dateTime.hour().minute()

    init(sourceIdFilter: String?, returning: LiveListReturn? = nil) {
        self.sourceIdFilter = sourceIdFilter
        self.returning = returning
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)
        setUpHeader()
        setUpColumns()
        setUpEmptyState()

        let store = LiveTVDataStore.shared
        Publishers.CombineLatest4(store.$channels, store.$sources, store.$recentChannelIds,
                                  store.$favoriteIds.combineLatest(store.$unfavoritedIds))
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        // A guide update changes what rows say, never which rows there are.
        store.$epg
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisibleRows() }
            .store(in: &cancellables)
        store.$isLoadingChannels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateEmptyState() }
            .store(in: &cancellables)

        Task { @MainActor in
            if store.channels.isEmpty { await store.loadChannels() }
            if store.epg.isEmpty { await store.loadEPG(startDate: Date(), hours: 12) }
            await store.refreshScheduledRecordings()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateClock()
        rebuild()
        minuteTimer?.invalidate()
        // What is on, and how far through, moves by the minute.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateClock()
                self?.refreshVisibleRows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Again on each appear: handlers are asked newest first.
        MenuPressInterceptor.register(self)
        // Back from the guide, nothing holds focus: the guide's focused cell
        // went with it. Ask the focus system directly for the channel's row.
        // Only then: on a tab switch focus is in the sidebar, and stays there.
        if claimsFocusOnAppear, let system = UIFocusSystem.focusSystem(for: view),
           (system.focusedItem as? UIView)?.isDescendant(of: view) != true, presentedViewController == nil {
            claimsFocusOnAppear = false
            let target = preferredFocusEnvironments.first ?? categoryView
            system.requestFocusUpdate(to: target)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        MenuPressInterceptor.resign(self)
        minuteTimer?.invalidate()
        minuteTimer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Back from the guide: bring the channel's row on screen, so it can be preferred.
        if let id = restoreChannelId, let indexPath = channelData.indexPath(for: id),
           channelView.cellForItem(at: indexPath) == nil {
            channelView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let pendingFocus { return [pendingFocus] }
        if let id = restoreChannelId, let indexPath = channelData.indexPath(for: id),
           let cell = channelView.cellForItem(at: indexPath) {
            return [cell]
        }
        return [categoryView]
    }

    // Right on a channel opens the guide: the press here, the swipe through
    // `guideSwipe`. Nothing lies to the right of a row, so the engine never
    // takes this move itself.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presentedViewController == nil,
              presses.contains(where: { $0.type == .rightArrow }), focusIsOnChannel() else {
            super.pressesBegan(presses, with: event)
            return
        }
        openGuide()
    }

    private func focusIsOnChannel() -> Bool {
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: channelView)
    }

    /// Only a fresh Right once focus is on a channel; the one that moved it there is spent.
    private func openGuide() {
        guard MenuPressInterceptor.remoteGestures.count != channelEntryGesture,
              let onOpenGuide, let categoryId = selectedId, let channelId = focusedChannelId(),
              let target = list.guideTarget(for: categoryId) else { return }
        onOpenGuide(target, channelId)
    }

    // Left from the channels: the guide between the columns now leads to the
    // selected category; from the categories, to the channels.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView else { return }
        // The return target applies to the first landing only.
        if next.isDescendant(of: view) { restoreChannelId = nil }
        if next.isDescendant(of: channelView), context.previouslyFocusedView?.isDescendant(of: channelView) != true {
            channelEntryGesture = MenuPressInterceptor.remoteGestures.count
        }
        if next.isDescendant(of: channelView) {
            columnGuide.preferredFocusEnvironments = [categoryView]
            categoryView.preferredFocusIndexPath = selectedCategoryIndexPath()
        } else if next.isDescendant(of: categoryView) {
            columnGuide.preferredFocusEnvironments = [channelView]
        }
    }

    // MARK: - Layout

    private static func makeLayout(rowHeight: CGFloat, spacing: CGFloat, sideInset: CGFloat) -> UICollectionViewLayout {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(rowHeight))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: sideInset, bottom: 0, trailing: sideInset)
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func setUpHeader() {
        titleLabel.font = .systemFont(ofSize: 56, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: 26, weight: .medium)
        countLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        clockLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        [titleLabel, countLabel, clockLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            clockLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.clockTop),
            clockLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.side),

            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.top),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.channelX),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 20),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Metrics.side),
        ])
    }

    private func setUpColumns() {
        for collection in [categoryView, channelView] as [UICollectionView] {
            collection.backgroundColor = .clear
            collection.contentInsetAdjustmentBehavior = .never
            collection.delegate = self
            collection.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(collection)
        }
        // Focus entering a column goes where `indexPathForPreferredFocusedView` says.
        categoryView.remembersLastFocusedIndexPath = false
        channelView.remembersLastFocusedIndexPath = false
        // The first capsule sits on the header's line; the row is 3pt taller than its capsule.
        categoryView.contentInset = UIEdgeInsets(top: Metrics.top - 3, left: 0, bottom: 60, right: 0)
        channelView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        categoryView.register(LiveCategoryCell.self, forCellWithReuseIdentifier: LiveCategoryCell.reuseID)
        channelView.register(LiveChannelRowCell.self, forCellWithReuseIdentifier: LiveChannelRowCell.reuseID)

        categoryData = UICollectionViewDiffableDataSource(collectionView: categoryView) { [weak self] cv, indexPath, id in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: LiveCategoryCell.reuseID, for: indexPath) as! LiveCategoryCell
            if let self, let category = self.list.category(id) {
                cell.configure(category, selected: id == self.selectedId,
                               collapsed: category.sourceId.map { self.collapsedSourceIds.contains($0) } ?? false)
            }
            return cell
        }
        channelData = UICollectionViewDiffableDataSource(collectionView: channelView) { [weak self] cv, indexPath, id in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: LiveChannelRowCell.reuseID, for: indexPath) as! LiveChannelRowCell
            if let self, let channel = self.shownById[id] {
                cell.configure(channel, nowNext: self.nowNext(channel))
            }
            return cell
        }

        channelView.addGestureRecognizer(TileLongPress.makeRecognizer(target: self, action: #selector(handleLongPress(_:))))
        guideSwipe = DirectionalInputBinding(
            gatedSwipesOn: channelView,
            directions: [.right],
            shouldHandle: { [weak self] _ in
                guard let self else { return false }
                return self.presentedViewController == nil && self.focusIsOnChannel()
            },
            onSwipe: { [weak self] _ in self?.openGuide() })

        view.addLayoutGuide(columnGuide)
        let outset = LiveChannelRowCell.platterOutset
        NSLayoutConstraint.activate([
            categoryView.topAnchor.constraint(equalTo: view.topAnchor),
            categoryView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            categoryView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.side),
            categoryView.widthAnchor.constraint(equalToConstant: Metrics.categoryWidth),

            // Wider than the rows by the platter's reach, so it is not clipped.
            channelView.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.top + Metrics.headerHeight),
            channelView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            channelView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.channelX - outset),
            channelView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -(Metrics.side - outset)),

            columnGuide.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.top),
            columnGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            columnGuide.leadingAnchor.constraint(equalTo: categoryView.trailingAnchor),
            columnGuide.trailingAnchor.constraint(equalTo: channelView.leadingAnchor),
        ])
        columnGuide.preferredFocusEnvironments = [channelView]
    }

    private func setUpEmptyState() {
        emptyLabel.text = String(localized: "No channels yet. Add a Live TV source in Settings.")
        emptyLabel.font = .systemFont(ofSize: 30, weight: .medium)
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        emptyLabel.isHidden = true
        spinner.color = .white
        spinner.hidesWhenStopped = true
        [emptyLabel, spinner].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Content

    /// Rebuilds the categories from the store, keeping the selection where it
    /// still exists. A selected row that went away (its last favourite
    /// removed) hands over to the first category.
    private func rebuild() {
        guard isViewLoaded else { return }
        list = LiveTVDataStore.shared.liveCategoryList(sourceIdFilter: sourceIdFilter,
                                                       collapsedSourceIds: collapsedSourceIds)
        let ids = list.categories.map(\.id)
        let existing = Set(categoryData.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        // Same ids, new counts: a row's identity never changes, so diffing alone never reaches it.
        snapshot.reconfigureItems(ids.filter(existing.contains))
        categoryData.apply(snapshot, animatingDifferences: false)

        // Back from the guide: its tab, and the channel focused there.
        if let returning {
            self.returning = nil
            claimsFocusOnAppear = true
            if let id = list.categoryId(for: returning.target) { selectedId = id }
            restoreChannelId = returning.channelId
            categoryView.preferredFocusIndexPath = selectedId.flatMap { categoryData.indexPath(for: $0) }
        }
        if selectedId.flatMap({ list.category($0) }) == nil {
            selectedId = list.categories.first { $0.kind != .sourceHeader }?.id
            categoryView.preferredFocusIndexPath = selectedId.flatMap { categoryData.indexPath(for: $0) }
        }
        showChannels()
        updateEmptyState()
    }

    /// The selected category's channels on the right. Within one category the
    /// rows diff, so focus stays put; a new category starts at its top.
    private func showChannels() {
        let channels = selectedId.map { list.channels(in: $0) } ?? []
        let sameCategory = selectedId == shownCategoryId
        let focusedId = sameCategory ? focusedChannelId() : nil
        let oldIds = shownIds
        shownCategoryId = selectedId
        shownIds = channels.map(\.id)
        shownById = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(shownIds)
        if sameCategory {
            snapshot.reconfigureItems(oldIds.filter { shownById[$0] != nil })
            channelData.apply(snapshot, animatingDifferences: false)
        } else {
            // Skips the diff: All Channels can hold tens of thousands of rows,
            // and focus walking the categories swaps them on every step.
            channelData.applySnapshotUsingReloadData(snapshot)
            channelView.setContentOffset(CGPoint(x: 0, y: -channelView.adjustedContentInset.top), animated: false)
        }

        let category = selectedId.flatMap { list.category($0) }
        titleLabel.text = category?.title
        countLabel.text = category.map { String(localized: "\($0.channelCount) channels") }

        // The focused row went away (a favourite removed): the next row takes
        // focus, or the one before at the end, or the categories when none is left.
        if let focusedId, shownById[focusedId] == nil {
            let index = oldIds.firstIndex(of: focusedId) ?? 0
            let target = oldIds[(index + 1)...].first { shownById[$0] != nil }
                ?? oldIds[..<index].last { shownById[$0] != nil }
            DispatchQueue.main.async { [weak self] in
                if let target { self?.focusChannel(target) } else { self?.focusSelectedCategory() }
            }
        }
    }

    private func selectCategory(_ id: String) {
        guard id != selectedId else { return }
        selectedId = id
        for case let cell as LiveCategoryCell in categoryView.visibleCells {
            guard let indexPath = categoryView.indexPath(for: cell) else { continue }
            cell.isSelectedRow = categoryData.itemIdentifier(for: indexPath) == id
        }
        showChannels()
    }

    private func toggleSection(_ sourceId: String) {
        if collapsedSourceIds.contains(sourceId) {
            collapsedSourceIds.remove(sourceId)
        } else {
            collapsedSourceIds.insert(sourceId)
        }
        // The header keeps its id, so it keeps focus; the channels stay as they are.
        rebuild()
    }

    private func nowNext(_ channel: UnifiedChannel, now: Date = Date()) -> LiveNowNext {
        LiveNowNext.of(LiveTVDataStore.shared.epg[channel.id], at: now)
    }

    /// Text and progress of the rows on screen, without a reload.
    private func refreshVisibleRows() {
        let now = Date()
        for case let cell as LiveChannelRowCell in channelView.visibleCells {
            guard let indexPath = channelView.indexPath(for: cell),
                  let id = channelData.itemIdentifier(for: indexPath),
                  let channel = shownById[id] else { continue }
            cell.configure(channel, nowNext: nowNext(channel, now: now), now: now)
        }
    }

    private func updateClock() {
        clockLabel.text = Date().formatted(Self.timeFormat)
    }

    private func updateEmptyState() {
        let empty = list.categories.isEmpty
        let loading = LiveTVDataStore.shared.isLoadingChannels
        if empty && loading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        emptyLabel.isHidden = !(empty && !loading)
        titleLabel.isHidden = empty
        countLabel.isHidden = empty
    }

    // MARK: - Focus

    private func requestFocus(_ environment: UIFocusEnvironment) {
        pendingFocus = environment
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // Left set, it would pull every later focus update back here.
        pendingFocus = nil
    }

    private func focusedChannelId() -> String? {
        TileLongPress.focusedCell(in: channelView).flatMap { channelData.itemIdentifier(for: $0) }
    }

    /// The selected category's row, or its source's header while it is folded away.
    private func selectedCategoryIndexPath() -> IndexPath? {
        guard let id = selectedId else { return nil }
        if let indexPath = categoryData.indexPath(for: id) { return indexPath }
        return list.category(id)?.sourceId
            .flatMap { categoryData.indexPath(for: LiveCategoryList.id(.sourceHeader, sourceId: $0)) }
    }

    private func focusSelectedCategory() {
        guard let indexPath = selectedCategoryIndexPath() else { return }
        categoryView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        categoryView.layoutIfNeeded()
        categoryView.preferredFocusIndexPath = indexPath
        requestFocus(categoryView)
    }

    private func focusChannel(_ id: String) {
        guard let indexPath = channelData.indexPath(for: id) else { return }
        channelView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        channelView.layoutIfNeeded()
        if let cell = channelView.cellForItem(at: indexPath) { requestFocus(cell) }
    }

    private func firstVisibleChannelIndexPath() -> IndexPath? {
        channelView.indexPathsForVisibleItems.min { $0.item < $1.item }
    }

    // MARK: - Actions

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let indexPath = TileLongPress.focusedCell(in: channelView),
              let id = channelData.itemIdentifier(for: indexPath),
              let channel = shownById[id] else { return }
        let frame = channelView.cellForItem(at: indexPath).map { $0.convert($0.bounds, to: nil) }
        LiveProgramMenu.present(
            program: nowNext(channel).current,
            channel: channel,
            from: self,
            sourceFrame: frame,
            onWatch: { [weak self] channel in self?.play(channel) },
            onMultiview: { [weak self] channel in self?.presentMultiview(adopting: nil, adding: channel) }
        )
    }

    /// Full screen on the glass rail, as from What's On. No corner player
    /// here, so Back ends the channel; focus comes back to the channel that
    /// was on screen, which may have changed in the player.
    private func play(_ channel: UnifiedChannel, adopting session: LiveTVSessionHandoff? = nil, animated: Bool = true) {
        let player = LiveTVAetherPlayerViewController(channel: channel, adopting: session)
        player.modalPresentationStyle = .fullScreen
        player.onOpenMultiview = { [weak self] session in
            self?.presentMultiview(adopting: session, adding: nil, fromPlayer: true)
        }
        player.onWatchWithScores = { [weak self, weak player] in
            player?.openMultiview { self?.presentMultiview(adopting: $0, adding: nil, fromPlayer: true, scores: true) }
        }
        player.onDismiss = { [weak self] channel in
            DispatchQueue.main.async { self?.focusChannel(channel.id) }
        }
        present(player, animated: animated)
    }

    /// `fromPlayer`: the full-screen player just closed without animation, and
    /// multiview takes over its picture (see `entersFromFullScreen`).
    private func presentMultiview(adopting session: LiveTVSessionHandoff?, adding channel: UnifiedChannel?,
                                  fromPlayer: Bool = false, scores: Bool = false) {
        let multiview = LiveMultiviewViewController(adopting: session, adding: channel,
                                                    sourceIdFilter: sourceIdFilter)
        multiview.entersFromFullScreen = fromPlayer
        multiview.startsWithScores = scores
        multiview.onWatchFullScreen = { [weak self] session in
            self?.play(session.channel, adopting: session, animated: false)
        }
        present(multiview, animated: !fromPlayer)
    }
}

// MARK: - Collection views

extension LiveListViewController: UICollectionViewDelegate {
    /// Entry into a column: the channels' first visible row, or the selected category.
    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        collectionView === channelView ? firstVisibleChannelIndexPath() : selectedCategoryIndexPath()
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard collectionView === categoryView,
              let indexPath = context.nextFocusedIndexPath,
              let id = categoryData.itemIdentifier(for: indexPath),
              let category = list.category(id) else { return }
        // A header folds its section; it never changes the channels.
        if category.kind != .sourceHeader { selectCategory(id) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === channelView {
            guard let id = channelData.itemIdentifier(for: indexPath), let channel = shownById[id] else { return }
            play(channel)
            return
        }
        guard let id = categoryData.itemIdentifier(for: indexPath), let category = list.category(id) else { return }
        if category.kind == .sourceHeader, let sourceId = category.sourceId {
            toggleSection(sourceId)
        } else if let first = firstVisibleChannelIndexPath(), let cell = channelView.cellForItem(at: first) {
            requestFocus(cell)
        }
    }
}

// MARK: - Menu and sidebar reselect

extension LiveListViewController: MenuBackHandling, SidebarTabReselecting {
    /// Menu on a channel goes to the categories. On a category it declines,
    /// so the sidebar opens.
    func handleMenuBack() -> Bool {
        // Focus must be in this page: a player or menu presented over it holds
        // focus in its own views, and Menu keeps its meaning there.
        guard isViewLoaded, presentedViewController == nil,
              let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
              focused.isDescendant(of: channelView) else { return false }
        focusSelectedCategory()
        return true
    }

    /// Both columns to the top, and focus on the first category.
    func reselectSidebarTab() {
        ScrollToTopTransition.perform(in: categoryView) {
            categoryView.setContentOffset(CGPoint(x: 0, y: -categoryView.adjustedContentInset.top), animated: false)
            if let first = list.categories.first(where: { $0.kind != .sourceHeader }) { selectCategory(first.id) }
            categoryView.layoutIfNeeded()
            focusSelectedCategory()
        }
    }
}
