import Foundation

/// 一条可逆的操作历史：只记录「改动前」的状态快照。
///
/// 撤回时把当前状态压进 future，恢复时再压回 past —— 于是可以来回走。
/// 任何一次新操作都会清空 future 分支，这一点和大多数编辑器一致：
/// 撤回两步之后又拖了一下滑杆，之前「恢复」的那条路就不存在了。
///
/// 刻意不依赖 SwiftUI / UIKit，编辑器与批量页共用同一份逻辑，
/// 也方便在命令行诊断里直接跑语义测试。
struct ReversibleHistory<Value> {

    /// 最多记多少步。批量页每一步都带着整队照片的引用，没必要记太深。
    var limit: Int

    private(set) var past: [Value] = []
    private(set) var future: [Value] = []

    init(limit: Int = 10) {
        self.limit = max(1, limit)
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    /// 还能往回退几步 / 还能往前恢复几步，诊断时打印用。
    var undoDepth: Int { past.count }
    var redoDepth: Int { future.count }

    /// 在改动发生之前调用，把「现在的样子」存进 past。
    mutating func record(_ current: Value) {
        past.append(current)
        if past.count > limit {
            past.removeFirst(past.count - limit)
        }
        future.removeAll()
    }

    /// 返回应该回退到的状态，同时把当前状态存进 future。
    mutating func undo(current: Value) -> Value? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    /// 返回应该恢复到的状态，同时把当前状态压回 past。
    mutating func redo(current: Value) -> Value? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }

    mutating func clear() {
        past.removeAll()
        future.removeAll()
    }

    /// 只丢掉「恢复」分支。
    /// 手动拖过滑杆之后，再按恢复会把刚才那点改动一起吃掉，
    /// 所以只要有新的手动改动，就当作 redo 这条路不存在了。
    mutating func clearRedo() {
        future.removeAll()
    }
}
