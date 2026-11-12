import SwiftUI

@MainActor
struct SearchView: View {
    @Bindable var viewModel: PlayerViewModel
    @EnvironmentObject private var appearance: AppearanceSettings
    @FocusState private var queryFocused: Bool

    var body: some View {
        let inputSelected = viewModel.selectedIndex == -1
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("输入歌曲或艺人", text: $viewModel.searchQuery,
                          prompt: Text("输入歌曲或艺人").foregroundStyle(inputSelected ? appearance.theme.selectionSecondaryInk : appearance.theme.lcdSecondaryText))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($queryFocused)
                    .onSubmit(search)
                    .accessibilityLabel("搜索歌曲或艺人")
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.clearSearch()
                        queryFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(inputSelected ? appearance.theme.selectionSecondaryInk : appearance.theme.lcdSecondaryText)
                            // A 16pt glyph was the whole hit target; this pads it
                            // out to the row's full height.
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索内容")
                }
                Button(action: search) {
                    Text("搜索")
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .fontWeight(.semibold)
                .buttonStyle(.plain)
                .disabled(viewModel.isSearching)
                // A disabled plain button looked exactly like an enabled one.
                .opacity(viewModel.isSearching ? 0.45 : 1)
                .animation(.easeOut(duration: 0.15), value: viewModel.isSearching)
            }
            .font(AppFont.title)
            .foregroundStyle(inputSelected ? appearance.theme.selectionInk : appearance.theme.lcdText)
            .padding(.horizontal, Metrics.horizontalInset)
            .frame(height: Metrics.singleLineRowHeight)
            .lcdSelectionBackground(inputSelected)
            .overlay(alignment: .bottom) {
                // The footer's hairline weight: the one divider on the LCD should
                // not outweigh the selection lens above it.
                Rectangle().fill(appearance.theme.footerDivider).frame(height: 1)
            }

            TrackRowsView(tracks: viewModel.searchResults,
                          selectedIndex: viewModel.selectedIndex,
                          stateMessage: viewModel.emptyStateMessage,
                          likedSpotifyTrackIDs: viewModel.likedSpotifyTrackIDs,
                          likedNetEaseTrackIDs: viewModel.likedNetEaseTrackIDs,
                          likeAnimation: viewModel.likeAnimation,
                          nowPlayingTrack: viewModel.currentTrack,
                          showsAlbum: true,
                          isLoadingMore: viewModel.isLoadingMoreSearch,
                          loadMoreFailed: viewModel.searchLoadMoreFailed,
                          onNearBottom: {
                              viewModel.loadMoreSearchResults()
                          },
                          onRetryLoadMore: {
                              viewModel.retryLoadMoreSearchResults()
                          }) { index in
                LCDKeyboard.dismiss()
                queryFocused = false
                viewModel.playSearchResult(at: index)
            }
            .id(viewModel.searchListID)
        }
        .onChange(of: viewModel.searchFocusRequest) { _, _ in
            queryFocused = true
        }
        .onChange(of: queryFocused) { _, focused in
            if focused { viewModel.selectSearchInput() }
        }
        // The keyboard is prewarmed behind the boot screen (see `KeyboardWarmup`),
        // so raising it as part of opening Search no longer stalls the transition:
        // the system is no longer starting its keyboard process on the main thread
        // here. Only the push out of the menu asks for it — returning from Now
        // Playing keeps the result rows clear instead of covering them again.
        .task {
            guard viewModel.consumeSearchKeyboardRequest() else { return }
            queryFocused = true
        }
        // Turning the wheel onto a result means the user is browsing, not typing.
        // The keyboard covers those rows (and most of the wheel), so it goes away
        // as soon as the selection leaves the input row.
        .onChange(of: viewModel.selectedIndex) { _, index in
            if index >= 0, queryFocused {
                LCDKeyboard.dismiss()
                queryFocused = false
            }
        }
        // A search started from the wheel's centre key (retry after a failure)
        // does not come through `search()`, so the keyboard goes away here too.
        .onChange(of: viewModel.isSearching) { _, searching in
            if searching, queryFocused {
                LCDKeyboard.dismiss()
                queryFocused = false
            }
        }
    }

    /// 3.1.5: the keyboard starts down first, in this run-loop turn, and only then
    /// does the search rebuild the result list. Setting the focus state alone let
    /// the keyboard wait for that rebuild.
    private func search() {
        LCDKeyboard.dismiss()
        queryFocused = false
        viewModel.performSearch()
    }
}

/// Every library collection shares the search-result rows and the surrounding LCD shell.
@MainActor
struct TrackListView: View {
    let viewModel: PlayerViewModel

    var body: some View {
        TrackRowsView(tracks: viewModel.browseTracks, selectedIndex: viewModel.selectedIndex,
                      stateMessage: viewModel.browseStateMessage,
                      likedSpotifyTrackIDs: viewModel.likedSpotifyTrackIDs,
                      likedNetEaseTrackIDs: viewModel.likedNetEaseTrackIDs,
                      likeAnimation: viewModel.likeAnimation,
                      nowPlayingTrack: viewModel.currentTrack) { index in
            viewModel.playBrowseTrack(at: index)
        }
        .id(viewModel.currentScreen)
    }
}

@MainActor
struct TrackRowsView: View {
    let tracks: [Track]
    let selectedIndex: Int
    let stateMessage: String?
    let likedSpotifyTrackIDs: Set<String>
    let likedNetEaseTrackIDs: Set<String>
    let likeAnimation: LikeAnimationEvent?
    var nowPlayingTrack: Track? = nil
    var showsAlbum = false
    var isLoadingMore = false
    var loadMoreFailed = false
    var onNearBottom: (() -> Void)? = nil
    var onRetryLoadMore: (() -> Void)? = nil
    let onPlay: (Int) -> Void
    @EnvironmentObject private var appearance: AppearanceSettings

    /// The retry row needs an identity that cannot collide with a track index.
    private static let loadMoreRowID = "loadMoreFailed"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if tracks.isEmpty || stateMessage != nil {
                        LCDEmptyState(message: stateMessage ?? "暂无歌曲",
                                      tint: appearance.theme.lcdSecondaryText)
                            .padding(.vertical, 24)
                    }
                    // Rows are addressed by index. Building one `Row` per track
                    // here allocated a 20,000-element array on every body pass,
                    // and the wheel changes `selectedIndex` on every step.
                    ForEach(tracks.indices, id: \.self) { index in
                        trackRow(at: index)
                    }
                    if loadMoreFailed {
                        selectableRow(index: tracks.count,
                                      title: L10n.text("加载失败，按中键重试"), subtitle: nil, showsChevron: false) {
                            onRetryLoadMore?()
                        }
                        .id(Self.loadMoreRowID)
                    }
                    if isLoadingMore {
                        Text("正在加载…")
                            .font(AppFont.caption)
                            .foregroundStyle(appearance.theme.lcdSecondaryText)
                            .padding(10)
                    }
                }
                // 3.1.5: one lens for the whole list, in the scroll content.
                .lcdLensHost()
            }
            .scrollIndicators(.hidden)
            .lcdEdgeFade(appearance.theme.lcdBackground)
            .modifier(LCDFastScrollIndex(selectedIndex: selectedIndex, count: tracks.count) { index in
                tracks.indices.contains(index) ? LCDFastScrollIndex.indexLetter(tracks[index].title) : nil
            })
            // Dragging the results puts the keyboard away at once instead of
            // dragging it down with the finger.
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: selectedIndex) { oldIndex, _ in
                scrollToSelection(proxy, leavingInput: oldIndex < 0, animated: true)
            }
            .onAppear { scrollToSelection(proxy, leavingInput: false) }
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy, leavingInput: Bool, animated: Bool = false) {
        guard selectedIndex >= 0 else {
            if !tracks.isEmpty { proxy.lcdFollow(0, anchor: .top, animated: animated) }
            else if loadMoreFailed { proxy.lcdFollow(Self.loadMoreRowID, anchor: .top, animated: animated) }
            return
        }
        if tracks.indices.contains(selectedIndex) {
            // Entering the list from the input scrolls minimally; wheel steps inside the list keep the selection centred.
            proxy.lcdFollow(selectedIndex, anchor: leavingInput ? nil : .center, animated: animated)
        } else if loadMoreFailed, selectedIndex == tracks.count {
            proxy.lcdFollow(Self.loadMoreRowID, anchor: .center, animated: animated)
        }
    }

    private func trackRow(at index: Int) -> some View {
        let track = tracks[index]
        return selectableRow(index: index, title: track.title, subtitle: subtitle(for: track)) {
            onPlay(index)
        } accessory: {
            trackAccessories(track)
        }
        .onAppear {
            if index >= max(0, tracks.count - 5) {
                onNearBottom?()
            }
        }
    }

    private func subtitle(for track: Track) -> String {
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard showsAlbum, !album.isEmpty, album != "未知专辑", album != track.title else { return track.artist }
        return track.artist + " · " + album
    }

    @ViewBuilder
    private func trackAccessories(_ track: Track) -> some View {
        if let nowPlayingTrack, nowPlayingTrack.source == track.source, nowPlayingTrack.id == track.id {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityLabel("正在播放")
        }
        if let likeID = track.spotifyTrackID ?? (track.source == .netease ? track.id : nil) {
            let likedIDs = track.source == .netease ? likedNetEaseTrackIDs : likedSpotifyTrackIDs
            TrackLikeHeart(
                isLiked: likedIDs.contains(likeID),
                confirmation: likeAnimation?.trackID == likeID ? likeAnimation : nil,
                showsOutline: true
            )
            .id(track.id)
        }
    }

    /// Titles and subtitles are catalogue data, so they bypass the app's UI-string translation.
    private func selectableRow<Accessory: View>(index: Int, title: String, subtitle: String?,
                                                showsChevron: Bool = true,
                                                action: @escaping () -> Void,
                                                @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
        let selected = index == selectedIndex
        return Button(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(AppFont.title)
                        .minimumScaleFactor(showsChevron ? 1 : 0.7)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(AppFont.detail)
                            .foregroundStyle(selected ? appearance.theme.selectionSecondaryInk : appearance.theme.lcdSecondaryText)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                accessory()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(selected ? appearance.theme.selectionSecondaryInk : appearance.theme.lcdSecondaryText)
                }
            }
            .padding(.horizontal, Metrics.horizontalInset)
            // Same rule as the menus: a second line makes the row 60pt.
            .frame(height: subtitle == nil ? Metrics.singleLineRowHeight : Metrics.doubleLineRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? appearance.theme.selectionInk : appearance.theme.lcdText)
            .lcdSelectionBackground(selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(LCDPressFeedbackStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Only a successful confirmation starts the effect. The actual liked state is
/// rendered immediately, so contains checks and failed optimistic toggles stay still.
@MainActor
struct TrackLikeHeart: View {
    let isLiked: Bool
    let confirmation: LikeAnimationEvent?
    let showsOutline: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var pulse: LikeAnimationEvent?
    @State private var pulseActive = false

    var body: some View {
        let pulseGate = pulseActive
        Text(isLiked ? "♥" : (showsOutline ? "♡" : "♥"))
            .foregroundColor(isLiked ? .red : .gray)
            .opacity(pulseGate ? 0 : (isLiked || showsOutline ? 1 : 0))
            .overlay {
                Text("♥")
                    .foregroundColor(.red)
                    .keyframeAnimator(initialValue: HeartAnimationValues(), trigger: pulse) { content, value in
                        content
                            .scaleEffect(value.scale)
                            .opacity(pulseGate ? value.opacity : 0)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            MoveKeyframe(pulse?.isLiked == true ? 0.5 : 1.0)
                            SpringKeyframe(pulse?.isLiked == true ? 1.3 : 0.8,
                                           duration: pulse?.isLiked == true ? 0.14 : 0.1,
                                           spring: Spring(response: 0.25,
                                                          dampingRatio: pulse?.isLiked == true ? 0.6 : 1.0))
                            SpringKeyframe(pulse?.isLiked == true ? 1.0 : 0.6,
                                           duration: pulse?.isLiked == true ? 0.18 : 0.1,
                                           spring: Spring(response: 0.25,
                                                          dampingRatio: pulse?.isLiked == true ? 0.6 : 1.0))
                        }
                        KeyframeTrack(\.opacity) {
                            MoveKeyframe(1.0)
                            LinearKeyframe(pulse?.isLiked == true ? 1.0 : 0.0,
                                           duration: pulse?.isLiked == true ? 0.32 : 0.2)
                        }
                    }
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13, weight: .semibold))
            .accessibilityLabel(isLiked ? "已喜欢" : "未喜欢")
            .allowsHitTesting(false)
            .onChange(of: confirmation) { _, event in
                guard scenePhase == .active, let event else { return }
                pulseActive = true
                pulse = event
            }
            .task(id: pulse?.id) {
                guard let pulse else { return }
                do {
                    try await Task.sleep(for: .milliseconds(pulse.isLiked ? 320 : 200))
                } catch { return }
                guard !Task.isCancelled else { return }
                pulseActive = false
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { pulseActive = false }
            }
            .onDisappear { pulseActive = false }
    }
}

private struct HeartAnimationValues {
    var scale: CGFloat = 1
    var opacity: Double = 0
}
