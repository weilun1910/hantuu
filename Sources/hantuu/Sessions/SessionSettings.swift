import Combine
import Foundation

/// Session and worktree preferences, kept in `<data folder>/sessions/settings.json` so a test
/// copy with its own data folder has its own. Also knows which projects are git repos, since
/// only those get the worktree option.
final class SessionSettings: ObservableObject {
    static let shared = SessionSettings()

    /// "Keep agents running after hantuu quits". On by default.
    @Published var keepAgentsRunning = true { didSet { if !loading { save() } } }
    /// Projects whose new chats start in their own worktree (the switch in the new-chat popover).
    @Published private(set) var worktreeProjects: Set<UUID> = []
    /// Project id to the top folder of its git repo, for projects inside one.
    @Published private(set) var gitRoots: [UUID: String] = [:]

    private var loading = false
    private var bag = Set<AnyCancellable>()

    private struct Stored: Codable {
        var keepAgentsRunning: Bool?
        var worktreeProjects: [UUID]?
    }

    private var file: URL { SessionHelper.dataFolder.appendingPathComponent("settings.json") }

    private init() { load() }

    func load() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        keepAgentsRunning = s.keepAgentsRunning ?? true
        worktreeProjects = Set(s.worktreeProjects ?? [])
    }

    func save() {
        let s = Stored(keepAgentsRunning: keepAgentsRunning, worktreeProjects: worktreeProjects.sorted { $0.uuidString < $1.uuidString })
        Paths.ensure(SessionHelper.dataFolder)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { try? data.write(to: file, options: .atomic) }
    }

    func usesWorktree(_ projectID: UUID) -> Bool { worktreeProjects.contains(projectID) }

    func setUsesWorktree(_ projectID: UUID, _ on: Bool) {
        if on { worktreeProjects.insert(projectID) } else { worktreeProjects.remove(projectID) }
        save()
    }

    func isGitRepo(_ projectID: UUID) -> Bool { gitRoots[projectID] != nil }

    /// Re-checks which projects are git repos whenever the project list changes.
    func watch(_ model: AppModel) {
        bag.removeAll()
        model.$projects
            .map { $0.map { ($0.id, $0.path) } }
            .sink { [weak self] list in self?.refreshGitRoots(list) }
            .store(in: &bag)
    }

    private var generation = 0

    private func refreshGitRoots(_ projects: [(UUID, String)]) {
        generation += 1
        let gen = generation
        DispatchQueue.global(qos: .utility).async {
            var roots: [UUID: String] = [:]
            for (id, path) in projects {
                if let r = Worktrees.repoRoot(of: path) { roots[id] = r }
            }
            DispatchQueue.main.async { if gen == self.generation { self.gitRoots = roots } }
        }
    }

    /// For the self test, which sets projects up by hand.
    func setGitRoot(_ projectID: UUID, _ root: String?) { gitRoots[projectID] = root }
}
