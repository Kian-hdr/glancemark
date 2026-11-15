import GlancemarkCore
import SwiftUI

struct FinderDocumentPreview: View {
    @State private var navigation: PreviewNavigation

    init(root: PreviewPage) {
        _navigation = State(initialValue: PreviewNavigation(root: root))
    }

    var body: some View {
        let page = navigation.page
        VStack(spacing: 0) {
            if navigation.canGoBack {
                navigationBar(for: page)
                Divider()
            }
            ReadingView(snapshot: page.snapshot, links: navigation.links, initialFragment: page.fragment,
                        useHostSurface: true, onUnavailableLocal: navigation.offerFolderAccess,
                        openLocal: navigation.openLocal)
                .environment(\.onPreviewMarkdownLink, navigation.openMarkdownLink)
                .id(page.id)
            if navigation.showsAccessHandoff {
                Divider()
                accessHandoff
            }
        }
        .onDisappear { navigation.cancelLoad() }
    }

    private func navigationBar(for page: PreviewPage) -> some View {
        HStack {
            Button(action: navigation.goBack) {
                Label("Back", systemImage: "chevron.left")
            }
            Text(page.document.lastPathComponent)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var accessHandoff: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quick Look couldn’t read the linked file.").fontWeight(.semibold)
                Text("Choose the folder that contains both notes to continue here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Choose Folder…", action: navigation.chooseFolder)
                .disabled(navigation.isChoosingFolder)
            Button(action: navigation.dismissFolderAccess) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(12)
        .background(.regularMaterial)
    }
}
