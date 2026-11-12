import Foundation

/// Window geometry stays global. Everything here belongs to one project, including files
/// opened outside its folder. Folder-relative review state lives under the checkout path.
struct ProjectPanelState: Codable {
    var tab: PanelTab?
    var codeTabs: [SavedCodeTab]?
    var selectedCodeTabID: UUID?
    var folders: [String: FolderPanelState]?
    var overviewScroll: Double?
    var overview: OverviewPanelState?
    var shells: [SavedPanelShell]?
    var selectedShellID: UUID?
    var browser: BrowserSavedState?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        tab = get(.tab)
        codeTabs = (get(.codeTabs) as [Lenient<SavedCodeTab>]?)?.compactMap(\.value)
        selectedCodeTabID = get(.selectedCodeTabID)
        folders = (get(.folders) as [String: Lenient<FolderPanelState>]?)?.compactMapValues(\.value)
        overviewScroll = get(.overviewScroll)
        overview = get(.overview)
        shells = (get(.shells) as [Lenient<SavedPanelShell>]?)?.compactMap(\.value)
        selectedShellID = get(.selectedShellID)
        browser = get(.browser)
    }
}

struct SavedPanelShell: Codable {
    var id: UUID
    var title: String
    var cwd: String? = nil
}

struct SavedCodeTab: Codable {
    var id: UUID
    var path: String
    var preview: Bool?
    var editor: EditorPosition?

    init(_ tab: CodeTab) {
        id = tab.id
        path = tab.path
        preview = tab.preview
        editor = tab.editorPosition
    }

    var restored: CodeTab {
        var tab = CodeTab(id: id, path: path)
        tab.kind = FileKinds.kind(of: path)
        tab.preview = preview ?? false
        tab.editorPosition = editor
        return tab
    }
}

struct EditorPosition: Codable, Equatable {
    struct Range: Codable, Equatable {
        var anchor: Int
        var head: Int
    }
    var ranges: [Range]?
    var mainIndex: Int?
    var top: Double?
    var left: Double?
    var previewTop: Double?
}

struct RepositoryPanelState: Codable {
    var base: DiffBase?
    var selectedPath: String?
    var diffScroll: [String: Double]?
}

struct FolderPanelState: Codable {
    var base: DiffBase?
    var selectedPath: String?
    var expandedRepositories: Set<String>?
    var showCleanRepositories: Bool?
    var focusedRepository: String?
    var repositories: [String: RepositoryPanelState]?
    var filter: String?
    var expanded: Set<String>?
    var selectedFile: String?
    var filesScroll: Double?
    var changesScroll: Double?
    var diffScroll: [String: Double]?
}

struct OverviewPanelState: Codable {
    var expandedAgents: Set<String>?
    var allAgents: Bool?
    var allTasks: Bool?
}
