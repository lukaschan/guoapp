import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var categories: [Category] = [.all]
    @State private var selectedCategory = ""
    @State private var items: [Drama] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var warning = ""
    @State private var loading = false
    @State private var error: String?
    @State private var categoriesSource = ""

    private var loadKey: String { appState.selectedSource + "|" + selectedCategory }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                categoryRow
                if appState.allSources {
                    sourceRow
                }
                if !warning.isEmpty {
                    Text(warning).font(.subheadline).foregroundColor(.secondary)
                }
                if loading && items.isEmpty {
                    Spacer()
                    HStack { Spacer(); ProgressView("正在加载…"); Spacer() }
                    Spacer()
                } else if let error, items.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Text(error).foregroundColor(.secondary).multilineTextAlignment(.center)
                        Button("重试") { Task { await reload(firstPage: true) } }
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    PosterGrid(items: items, onReachEnd: {
                        Task { await loadMore() }
                    })
                    if loading && !items.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView("正在加载…")
                            Spacer()
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .padding(.horizontal, 48)
            .navigationDestination(for: Drama.self) { drama in
                DetailView(drama: drama)
            }
            .task(id: loadKey) {
                await reload(firstPage: true)
            }
        }
    }

    private var sourceRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SourceSite.available(allSources: appState.allSources)) { site in
                    let selected = site.id == appState.selectedSource
                    Button(site.name) {
                        selectedCategory = ""
                        appState.selectedSource = site.id
                    }
                    .font(.system(size: 16))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(selected ? Color.white : Color.white.opacity(0.12))
                    .foregroundColor(selected ? .black : .white)
                    .cornerRadius(8)
                }
            }
        }
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories) { category in
                    let selected = category.id == selectedCategory
                    Button(category.name) {
                        selectedCategory = category.id
                    }
                    .font(.system(size: 16))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(selected ? Color.white : Color.white.opacity(0.12))
                    .foregroundColor(selected ? .black : .white)
                    .cornerRadius(8)
                }
            }
        }
    }

    private func reload(firstPage: Bool) async {
        if firstPage { page = 1 }
        loading = true
        error = nil
        do {
            if categoriesSource != appState.selectedSource {
                let fetched = try await CoreClient.shared.categories(
                    source: appState.selectedSource
                )
                // 核心返回的分类里可能自带“全部”，与本地的 .all 重复；
                // 按名称去重，保留第一个（即本地的 .all）。
                var seenNames = Set<String>()
                categories = ([.all] + fetched).filter { seenNames.insert($0.name).inserted }
                categoriesSource = appState.selectedSource
            }
            let result = try await CoreClient.shared.catalog(
                source: appState.selectedSource, page: page, category: selectedCategory
            )
            if firstPage {
                items = result.items
            } else {
                items += result.items
            }
            hasMore = result.hasMore
            warning = result.warning
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func loadMore() async {
        guard hasMore, !loading else { return }
        page += 1
        await reload(firstPage: false)
    }
}
