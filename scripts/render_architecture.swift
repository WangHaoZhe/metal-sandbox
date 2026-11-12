// Render with AppKit; select --language en|zh and optionally --runtime-flow.
import AppKit
import Foundation
import Darwin
func color(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: alpha)
}
let ink = color(0x152B46), muted = color(0x53667D), background = color(0xF4F7FB)
let blue = color(0x235EAE), teal = color(0x147466), orange = color(0xA85C0C)
let docs = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs")

let usage = "Usage: swift scripts/render_architecture.swift [--language en|zh] [--runtime-flow]\n"
var arguments = Array(CommandLine.arguments.dropFirst())
let language: String
if let index = arguments.firstIndex(of: "--language") {
    guard arguments.indices.contains(index + 1), ["en", "zh"].contains(arguments[index + 1]) else {
        fputs(usage, stderr)
        exit(2)
    }
    language = arguments.remove(at: index + 1)
    arguments.remove(at: index)
} else {
    language = "en"
}
guard arguments.isEmpty || arguments == ["--runtime-flow"] else {
    fputs(usage, stderr)
    exit(2)
}
let outputDirectory = language == "zh" ? docs.appendingPathComponent("zh") : docs
func label(_ english: String, _ chinese: String) -> String {
    language == "zh" ? chinese : english
}

final class Canvas {
    let width: CGFloat = 1720
    let height: CGFloat
    let bitmap: NSBitmapImageRep
    let graphics: NSGraphicsContext
    let ctx: CGContext
    var warnings: [String] = []
    init(height: CGFloat) {
        self.height = height
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3440,
            pixelsHigh: Int(height * 2), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("bitmap allocation failed") }
        bitmap = rep; self.graphics = graphics; ctx = graphics.cgContext
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        ctx.scaleBy(x: 2, y: 2); ctx.setShouldAntialias(true)
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: height - y - h, width: w, height: h)
    }
    func pt(_ p: (CGFloat, CGFloat)) -> CGPoint { CGPoint(x: p.0, y: height - p.1) }
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
             fill: NSColor = .white, stroke: NSColor = color(0xC2CDDB),
             dash: Bool = false, radius: CGFloat = 14, lineWidth: CGFloat = 1.8) {
        ctx.saveGState()
        let path = CGPath(roundedRect: rect(x,y,w,h), cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path); ctx.setFillColor(fill.cgColor); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(lineWidth)
        if dash { ctx.setLineDash(phase: 0, lengths: [9,7]) }
        ctx.strokePath(); ctx.restoreGState()
    }
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
              size: CGFloat = 18, weight: NSFont.Weight = .regular, tint: NSColor = ink,
              align: NSTextAlignment = .left, spacing: CGFloat = 3, mono: Bool = false) {
        let style = NSMutableParagraphStyle(); style.alignment = align
        style.lineBreakMode = .byWordWrapping; style.lineSpacing = spacing
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: tint, .paragraphStyle: style])
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let need = a.boundingRect(with: NSSize(width: w, height: 10000), options: options).height
        if need > h + 1 { warnings.append("\(Int(need)) > \(Int(h)): \(s)") }
        a.draw(with: rect(x,y,w,h), options: options)
    }
    func arrow(_ points: [(CGFloat,CGFloat)], tint: NSColor = color(0x74879D), dash: Bool = false,
               thickness: CGFloat = 2.2, head: CGFloat = 8) {
        guard points.count >= 2 else { return }
        ctx.saveGState(); ctx.setStrokeColor(tint.cgColor); ctx.setFillColor(tint.cgColor)
        ctx.setLineWidth(thickness); ctx.setLineJoin(.round)
        if dash { ctx.setLineDash(phase: 0, lengths: [6,5]) }
        let path = CGMutablePath(); path.move(to: pt(points[0]))
        for p in points.dropFirst() { path.addLine(to: pt(p)) }
        ctx.addPath(path); ctx.strokePath()
        let a = points[points.count-2], b = points[points.count-1]
        let dx = b.0-a.0, dy = b.1-a.1, n = hypot(dx,dy)
        if n > 0 {
            let ux = dx/n, uy = dy/n
            let tri = CGMutablePath(); tri.move(to: pt(b))
            tri.addLine(to: pt((b.0-ux*head-uy*head*0.5, b.1-uy*head+ux*head*0.5)))
            tri.addLine(to: pt((b.0-ux*head+uy*head*0.5, b.1-uy*head-ux*head*0.5)))
            tri.closeSubpath(); ctx.addPath(tri); ctx.fillPath()
        }
        ctx.restoreGState()
    }
    func card(_ title: String, _ body: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
              accent: NSColor, titleSize: CGFloat = 19, bodySize: CGFloat = 16.5) {
        box(x,y,w,h,stroke: accent.withAlphaComponent(0.4),radius: 11,lineWidth: 1.5)
        text(title,x+16,y+12,w-32,30,size:titleSize,weight:.semibold,tint:accent)
        text(body,x+16,y+48,w-32,h-56,size:bodySize,tint:muted)
    }
    func save(_ filename: String) throws {
        NSGraphicsContext.restoreGraphicsState()
        guard warnings.isEmpty else {
            for warning in warnings { fputs("LAYOUT \(filename): \(warning)\n",stderr) }
            throw NSError(domain:"DiagramLayout", code:1, userInfo:[NSLocalizedDescriptionKey:"text overflow"])
        }
        bitmap.size = NSSize(width: width,height: height)
        guard let bytes = bitmap.representation(using:.png,properties:[:]) else { fatalError("PNG encoding failed") }
        let output = outputDirectory.appendingPathComponent(filename)
        try bytes.write(to:output,options:.atomic)
        print("Wrote \(output.path) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh), \(bytes.count) bytes)")
    }
}

if arguments == ["--runtime-flow"] {
    let r = Canvas(height: 2980)
    let data = color(0x637083)
    r.text(label("Metal Sandbox · Complete Runtime Flow", "Metal Sandbox · 完整运行框图"),70,30,1580,62,size:36,weight:.bold)
    r.text(label("Current implementation: creation and preparation → Agent tool loop → verification → snapshots and lifecycle", "当前实现：创建与准备 → Agent 工具循环 → 验收 → 快照与实例生命周期"),70,100,1580,34,size:22,tint:muted)
    for (x, title, tint) in [(70.0,label("Control plane / CLI", "控制面 / CLI"),blue),(350.0,label("Sandbox processes", "Sandbox 内进程"),teal),(700.0,label("Scheduling / waiting", "调度与等待"),orange),(1010.0,label("Files / records", "文件与记录"),data)] {
        r.box(x,148,14,14,fill:tint,stroke:tint,radius:3)
        r.text(title,x+24,140,270,28,size:18,tint:muted)
    }

    r.box(70,180,1580,610,fill:color(0xF8FAFD),stroke:color(0xC2CDDB))
    r.text(label("A  Startup, creation, and preparation", "A  启动、创建与准备"),95,197,1490,38,size:25,weight:.bold)
    r.card(label("1  User entry", "1  用户入口"), label("App buttons or sandboxctl in a terminal\nNo direct access to instance files or processes", "App 按钮，或终端中的 sandboxctl\n前端不直接操作实例文件和底层进程"),100,250,440,116,accent:blue)
    r.card(label("2  CLI request", "2  CLI 请求"), label("create / import / exec / verify / …\nLocal Unix socket; permission checks", "create / import / exec / verify / …\n本地 Unix socket；校验操作权限"),635,250,440,116,accent:blue)
    r.card(label("3  Service: metal-sandboxd", "3  管理服务 metal-sandboxd"), label("Started by App or terminal; manages instances\nClosing the frontend leaves service/tasks running", "由 App 或终端启动，监听请求并管理实例\n关闭前端不会关闭服务或已提交任务"),1170,250,440,116,accent:blue)
    r.arrow([(540,308),(635,308)],tint:blue)
    r.arrow([(1075,308),(1170,308)],tint:blue)
    r.arrow([(1390,366),(1390,391),(320,391),(320,425)],tint:blue)

    r.card(label("4  Create N instances", "4  创建 N 个实例"), label("Allocate by node load/capacity within a pool\nSave ID, name, network, environment, policy\nConfigure each instance independently", "在选定池内按节点负载与容量分配\n保存 ID、名称、网络、环境变量和策略\n每个实例独立配置"),100,425,440,125,accent:blue)
    r.card(label("5  Sign and start a separate Host", "5  签名并启动独立 Host"), label("Apple App Sandbox; descendants inherit limits\nCreate workspace / private HOME / tmp\nInitial empty snapshot (see step 22)", "Apple App Sandbox；子进程继承限制\n建立 workspace / 私有 HOME / tmp\n生成初始空快照（快照流程见 22）"),635,425,440,125,accent:teal)
    r.card(label("6  Import and archive task package", "6  导入题包与存档"), label("Copy agent/ contents to workspace root\nArchive tests/ by content SHA-256 in backend\nShare identical archives; defer test injection", "agent/ 的内容复制到 workspace 根\ntests/ 按内容 SHA-256 存档在后端\n相同测试共用存档，做题期间不注入"),1170,425,440,125,accent:blue)
    r.arrow([(540,488),(635,488)],tint:blue)
    r.arrow([(1075,488),(1170,488)],tint:blue)
    r.arrow([(1390,550),(1390,582),(320,582),(320,615)],tint:blue)

    r.card(label("7  Run preparation script", "7  执行准备脚本"), label("Save setup.sh; submit with --session\nInject environment; register tests and timeout\ncwd = workspace; script installs tools", "保存 setup.sh，以 --session 提交\n注入环境，登记测试版本和独立超时\ncwd 为 workspace；脚本自行安装工具"),100,615,440,135,accent:teal)
    r.card(label("8  Task package starts harness", "8  题包启动 harness"), label("Current packages: Claude in private HOME\nConfigure PreToolUse and shell prefix\nPass full instruction.md through stdin", "当前题包：在私有 HOME 安装 Claude\n配置 PreToolUse 与 shell prefix\ninstruction.md 原文从 stdin 传入"),635,615,440,135,accent:teal)
    r.card(label("9  Concurrent Agent sessions", "9  多个主会话并行运行"), label("Claude CLI ↔ external model API\nCLI inside Sandbox; network per instance\nReasoning/output do not occupy the serial slot", "Claude CLI ↔ 外部模型接口\nCLI 在 Sandbox 内；联网受实例开关控制\n思考/输出不占用节点串行槽"),1170,615,440,135,accent:teal)
    r.arrow([(540,683),(635,683)],tint:blue)
    r.arrow([(1075,683),(1170,683)],tint:blue)
    r.arrow([(860,790),(860,815)],tint:blue)

    r.box(70,815,1580,970,fill:color(0xF8FAFD),stroke:color(0xC2CDDB))
    r.text(label("B  Complete round trip of a tool call", "B  一次工具调用的完整往返"),95,835,1300,38,size:25,weight:.bold)
    r.card(label("10  Claude issues a tool call", "10  Claude 发出工具调用"), label("Bash: ordinary familiar shell commands\nOther tools take the branch on the right\nSession completion proceeds to C", "Bash：用户熟悉的普通 shell 命令\n其他工具走右侧分支；结束则进入 C"),100,905,440,120,accent:teal)
    r.card("Read / Write / Edit / Glob / Grep", label("Harness reads/writes/searches inside instance\nNo Bash hook or serial queue\nResults return directly to Claude", "由 harness 在实例内读写、查找文件\n不经过 Bash hook / 串行队列\n结果直接返回 Claude"),635,905,440,120,accent:teal)
    r.card(label("Terminal / exec / enter", "终端 / exec / enter"), label("These entries need no Claude hook\nClassify by instance policy; schedule (13)\nExecute inside native App Sandbox", "这些入口不需要 Claude hook\n按实例策略分类、进入调度（13）\n命令在原生 App Sandbox 内执行"),1170,905,440,120,accent:blue)
    r.arrow([(540,965),(635,965)],tint:teal)
    r.arrow([(320,1025),(320,1100)],tint:teal)
    r.text("Bash",333,1046,150,28,size:18,tint:teal)
    r.arrow([(1390,1025),(1390,1100)],tint:blue)

    r.card("11  PreToolUse hook", label("Record original command; add correlation tag\nClaude invokes helper through shell prefix\nAgent need not write gpu-run or sandboxctl", "记录原始命令，添加关联标记\nClaude 再通过 shell prefix 调用 helper\nAgent 不用写 gpu-run 或 sandboxctl"),100,1100,440,132,accent:teal)
    r.card(label("12  sandbox-shell classifies command", "12  sandbox-shell 判断命令"), label("Read original command; resolve cwd / PATH\nMatch instance allowlist / denylist\nUse Host-provided real container boundaries", "取回原始命令，按实际 cwd / PATH 查找\n匹配实例的白名单 / 黑名单\n使用 Host 提供的真实容器目录边界"),635,1100,440,132,accent:teal)
    r.card(label("13  Host → manager", "13  Host → 管理器"), label("Register Bash subtask through private IPC\nLink parent session; execution node grants permit\nNo Bash process starts without permission", "通过私有 IPC 登记 Bash 子任务\n关联父会话，由执行节点发放许可\n没有许可，不启动该条 Bash"),1170,1100,440,132,accent:blue)
    r.arrow([(540,1166),(635,1166)],tint:teal)
    r.arrow([(1075,1166),(1170,1166)],tint:blue)

    r.card(label("Command classification", "命令分类规则"), label("Allowlist: all static commands match → parallel\nOtherwise (including unparseable) → serial\nDenylist: whole task matches → serial\nNo match → parallel", "白名单：各静态子命令均匹配 → 并行\n其余（含无法解析）→ 串行\n黑名单：整条任务命中 → 串行\n未命中 → 并行"),100,1320,440,170,accent:orange,bodySize:16)
    r.card(label("14  Parallel path", "14  并行通道"), label("Register separate lease; grant permit directly\nNo wait for serial slot or same-instance tasks\nExamples: ordinary ls / cat / clang", "登记独立租约，直接发放许可\n不等待串行槽，也不等待同实例其他任务\n示例：普通 ls / cat / clang"),635,1330,440,130,accent:orange)
    r.card(label("15  Serial path and scheduling pool", "15  串行通道与调度池"), label("One independent FIFO serial slot per node\nDynamic handoff to available same-pool nodes\nBoth switches and receiver pool limits must allow", "每个节点独立使用一个 FIFO 串行槽\n动态调度只转交同池的可用节点\n双方开关与接收端池限制均须允许"),1170,1330,440,130,accent:orange)
    r.arrow([(1390,1232),(1390,1278),(855,1278),(855,1330)],tint:orange)
    r.arrow([(1390,1278),(1390,1330)],tint:orange)
    r.arrow([(1390,1460),(1390,1498),(855,1498)],tint:orange)
    r.arrow([(855,1460),(855,1498),(585,1498),(585,1525)],tint:orange)

    r.card(label("16  After permission: run in the execution node's Sandbox", "16  获准后，在执行节点的 Sandbox 运行"), label("Workspace and HOME stay on owner; same-pool nodes access the same paths through SMB\nPreserve Bash and user variables; resolve local toolchain; source-private dependencies stay local\nMetal program → Metal.framework → node driver → physical Apple GPU", "工作区和 HOME 保存在所属节点；同池节点通过 SMB 直接访问同一路径\n保持 Bash 和用户变量；工具链按执行节点解析，源节点私有依赖留在本机\nMetal 程序 → Metal.framework → 节点驱动 → 实体 Apple GPU"),100,1525,975,160,accent:teal,bodySize:18)
    r.card(label("17  Return result and release permit", "17  返回结果并释放许可"), label("stdout / stderr / exit code return to Claude\nReport completion; release lease after cleanup\nClaude uses result for next round (back to 10)", "stdout / stderr / 退出码返回 Claude\n上报执行结束；完成清理后释放租约\nClaude 根据结果继续下一轮（回 10）"),1170,1525,440,160,accent:blue,bodySize:17)
    r.arrow([(1075,1605),(1170,1605)],tint:blue)
    r.arrow([(1610,1585),(1632,1585),(1632,879),(320,879),(320,905)],tint:blue,dash:true)
    r.text(label("Next round", "下一轮"),1480,850,125,25,size:17,tint:blue)
    r.text(label("Count = top-level sessions/commands + active or queued Bash subtasks; both paths register lifecycle.\nScheduling covers the entire task and descendants; physical GPU hardware is managed by the system.", "计数 = 顶层会话/命令 + 活跃或排队的 Bash 子任务；两条通道都登记生命周期。\n调度覆盖整条任务及其子进程；GPU 使用实体硬件，由系统管理。"),100,1705,1510,58,size:18,tint:muted)
    r.arrow([(860,1785),(860,1810)],tint:blue)

    r.box(70,1810,1580,500,fill:color(0xF8FAFD),stroke:color(0xC2CDDB))
    r.text(label("C  Agent completion, result viewing, and verification", "C  Agent 结束、结果观察与验收"),95,1830,1490,38,size:25,weight:.bold)
    r.card(label("18  Agent session finishes", "18  Agent 会话结束"), label("Verify normal/nonzero exits and cleaned timeouts\nExplicit cancellation/stop cancels later verification\nInstance, code, renders, and sessions remain", "正常、非零退出及清理后的超时均可验收\n主动取消或停止会取消后续自动验收\n实例、代码、渲染结果和会话保留"),100,1880,440,140,accent:teal)
    r.card(label("19  Automatic / manual verification", "19  自动验收 / 手动 verify"), label("Wait for instance tasks and confirmed cleanup\nReplace entire tests/ from backend archive\nReads only; no other execution or writes", "等待本实例任务结束并确认清理\n从后端存档替换整个 tests/ 目录\n验收期间允许读取，禁止其他执行与写入"),635,1880,440,140,accent:blue)
    r.card(label("20  Run tests/test.sh", "20  运行 tests/test.sh"), label("cwd = workspace/tests; node-local serial\nSeparate runtime timeout; writes only in tests/\nSave Agent and verifier execution results separately", "cwd 为 workspace/tests；在执行节点串行\n独立运行超时，测试只在 tests/ 内写入\n分别保存 Agent 与验收执行结果"),1170,1880,440,140,accent:teal)
    r.arrow([(540,1950),(635,1950)],tint:blue)
    r.arrow([(1075,1950),(1170,1950)],tint:blue)

    r.card(label("workspace: task artifacts", "workspace：做题产物"), label("Source, binaries, images, existing tests/\nTests may write tests/result.json, metrics.json\nFiles tab uses ls / read / reveal-file", "源码、二进制、图片、已有 tests/\n测试可生成 tests/result.json、metrics.json\n文件页通过 ls / read / reveal-file 查看"),100,2075,440,165,accent:data)
    r.card(label("Private HOME: tools and trajectories", "私有 HOME：工具与轨迹"), label("Separate Claude installation, config, session JSONL\nRecorded during execution; retained after exit\nTrajectory tab: incremental graphical display\nExcluded from workspace snapshots", "独立安装的 Claude、配置和会话 JSONL\n运行中持续记录，会话结束后保留\n轨迹页调用 trajectory，增量图形化显示\n不包含在 workspace 快照中"),635,2075,440,165,accent:data)
    r.card(label("Backend: test history and versions", "后端：验收历史与测试版本"), label("executions/<execution_id>.json: state/output\nverification_results/<execution_id>.zip: metrics\ntest_packages/<content_hash>/tests.zip\nVerification tab reads history through public CLI", "executions/<执行ID>.json：状态及输出\nverification_results/<执行ID>.zip：metrics\ntest_packages/<内容哈希>/tests.zip\n验收页通过公开 CLI 读取历史记录"),1170,2075,440,165,accent:data,bodySize:16)
    r.arrow([(320,2020),(320,2075)],tint:data,dash:true)
    r.arrow([(540,1980),(580,1980),(580,2048),(855,2048),(855,2075)],tint:data,dash:true)
    r.arrow([(1390,2020),(1390,2075)],tint:data,dash:true)
    r.text(label("Ordinary command completion creates no snapshot. Restart resumes unsubmitted verification; submitted executions are not replayed; errors require inspection.", "普通命令结束不创建快照；服务重启续接尚未提交的验收；已提交的执行不重放，异常需要人工检查。"),100,2260,1505,34,size:18,tint:muted)
    r.arrow([(860,2310),(860,2335)],tint:blue)

    r.box(70,2335,1580,605,fill:color(0xF8FAFD),stroke:color(0xC2CDDB))
    r.text(label("D  Save, stop, restart, and delete", "D  保存、停止、再次启动与删除"),95,2355,1490,38,size:25,weight:.bold)
    r.card(label("21  Choose a lifecycle operation", "21  选择生命周期操作"), label("Save/export: wait for an idle instance\nStop: cancel tasks and wait for exit/cleanup\nAll three attempt to update workspace snapshot", "保存/导出：实例空闲后处理\n停止：先取消任务并等待退出清理\n三者都会尝试更新工作区快照"),100,2405,440,170,accent:blue)
    r.card(label("22  Complete snapshot pipeline", "22  完整快照流水线"), label("Full ZIP → write while computing SHA-256\nOne extraction: CRC + paths + count/size\nAtomic replacement; retain old ZIP on failure\nBuilt-in: state-dir/checkpoints/<id>.zip", "全量 ZIP → 接收时边写边算 SHA-256\n一次解压：CRC + 路径 + 数量/大小\n成功原子替换；失败保留旧 ZIP\n内置：状态目录/checkpoints/<id>.zip"),635,2405,440,170,accent:orange,bodySize:16)
    r.card(label("23  Operation completes", "23  操作完成"), label("Stop: attempt snapshot, close Host → stopped\nSave/export: return without state change\nExport ZIP to a user-selected destination", "停止：快照尝试后关闭 Host → stopped\n保存/导出：返回，实例状态不变\n导出另存 ZIP 到用户选择的位置"),1170,2405,440,170,accent:blue)
    r.arrow([(540,2490),(635,2490)],tint:blue)
    r.arrow([(1075,2490),(1170,2490)],tint:blue)
    r.arrow([(1390,2575),(1390,2600),(320,2600),(320,2635)],tint:blue)
    r.arrow([(855,2600),(855,2635)],tint:blue)
    r.arrow([(1390,2600),(1390,2635)],tint:blue)

    r.card(label("24  Start original instance · start", "24  启动原实例 · start"), label("Retain ID, workspace, private HOME; restart Host\nNever overwrite workspace with an old ZIP\nContinue commands or restart Agent as needed", "保留 ID、目录和私有 HOME，重新启动 Host\n不会用旧 ZIP 覆盖原工作区\n按需继续执行或重新启动 Agent"),100,2635,440,140,accent:blue)
    r.card(label("25  Clone snapshot · restore", "25  从快照克隆 · restore"), label("Verify saved ZIP; create a new ID\nCopy workspace only, excluding private HOME\nVerification can run in clone (19)", "校验已保存 ZIP，创建新 ID\n只复制 workspace，不复制私有 HOME\n可在克隆实例执行验收（19）"),635,2635,440,140,accent:blue)
    r.card(label("26  Delete · delete (stop first)", "26  删除 · delete（需先停止）"), label("Remove workspace, private HOME, built-in ZIP\nRetain external ZIPs and separate audit records\nReport remaining system container shells", "工作区、私有 HOME、内置 ZIP 一并删除\n外部导出 ZIP 与独立审计记录保留\n系统容器空壳残留会明确提示"),1170,2635,440,140,accent:blue)

    r.box(100,2820,1510,96,fill:color(0xFFF8EE),stroke:orange,radius:10)
    r.text(label("Cancellation / timeout / cleanup errors", "取消 / 超时 / 清理异常"),118,2831,1470,27,size:20,weight:.semibold,tint:orange)
    r.text(label("Confirmed process-group cleanup releases permits. Host loss or uncertain cleanup requires recovery; queued commands resume, failed commands do not replay.\nCritical thermal state pauses new permits. Connected Agent sessions may remain during recovery; CPU cleanup does not establish GPU drain.", "进程组清理确认后释放许可；运行中 Host 失联、清理不确定等需要人工恢复。隔离期间命令等待，恢复后继续；失败命令不重放。\ncritical 热状态暂停新许可；正常 Agent 会话可在恢复期间保留。CPU 清理不等于 GPU 排空。"),118,2865,1470,47,size:17,tint:muted)
    r.text(label("Solid: call / execution order    Dashed: data / returned results    Compile directly in native Sandbox; no Build Broker.", "实线：调用 / 执行顺序    虚线：数据 / 结果返回    编译直接在原生 Sandbox 内进行，当前没有 Build Broker。"),70,2950,1580,28,size:17,tint:muted)
    try r.save("runtime_flow.png")
    exit(0)
}

let c = Canvas(height: 1690)
c.text("Metal Sandbox · Architecture",70,35,1580,62,size:38,weight:.bold)
c.text(label("SwiftUI / Liquid Glass · Separate CLI · Native App Sandbox · Task allowlist/denylist scheduling", "SwiftUI / Liquid Glass · CLI 解耦 · 原生 App Sandbox · 任务黑白名单调度"),70,104,1580,35,size:23,tint:muted)
c.box(70,173,1580,692,fill:color(0xEDF3FC),stroke:blue)
c.text(label("Trusted control plane / Host processes", "可信控制面 / Host processes"),95,190,1490,40,size:25,weight:.bold,tint:blue)
c.card(label("Metal Sandbox.app · Separate SwiftUI frontend", "Metal Sandbox.app · 独立 SwiftUI 前端"), label("Foundation.Process + argv → public CLI; no internal credentials/state/containers or direct socket access\nNative Liquid Glass controls; closing GUI leaves service running; matching CLI runtime bundled", "Foundation.Process + argv -> 现有 CLI；不读内部凭据/状态/容器，不直接连 socket\n原生 Liquid Glass 导航/控件；GUI 退出不停止服务；内置同版本命令行运行时"),100,245,1520,112,accent:blue)
c.arrow([(500,357),(500,400)],tint:blue)
c.arrow([(1340,357),(1340,400)],tint:blue)
c.card(label("evaluation-runner · Infrastructure self-tests", "evaluation-runner · 基础设施自测"), label("AgentDriver / tool observation / EpisodeController\nFrozen artifacts + SHA-256 + trace.jsonl\nVerifier in a separate instance; external host checks full results", "AgentDriver / 工具观察 / EpisodeController\n冻结产物 + SHA-256 + trace.jsonl\nVerifier：独立实例运行，宿主外部检查完整结果"),100,400,930,166,accent:blue)
c.card("sandboxctl", label("Batch creation / per-instance exec / console\nFile read/write / checkpoints / cancel / recover\nFoundation · AF_UNIX · scoped capability", "批量创建 / 指定实例 exec / 命令控制台\n文件读写 / 检查点 / 取消 / 恢复\nFoundation · AF_UNIX · scoped capability"),1060,400,560,166,accent:blue)
c.arrow([(850,566),(850,600)],tint:blue)
c.arrow([(1340,566),(1340,600)],tint:blue)
c.card("metal-sandboxd / NativeManager / ClusterController", label("Instance lifecycle · ZIP snapshots · test archives · automatic verification · separate execution records\nPool placement · serial reservations/reselection · target toolchains · private-path checks · SSH CLI relay", "实例生命周期 · ZIP 快照 · tests 存档 · 自动验收 · 独立执行记录\n按池创建 · 串行预约与重选 · 目标工具链解析 · 私有路径检查 · SSH CLI relay"),100,600,1520,112,accent:blue)
c.arrow([(850,712),(850,742)],tint:orange)
c.card(label("Task allowlist/denylist scheduler", "任务黑白名单调度层"), label("Allowlist matches run in parallel; denylist matches serially; one serial slot per node; verification always serial\nTaskPolicy / ExecutionScheduler · separate leases · cancellation cleanup · quarantine on uncertainty · no GPU exclusivity guarantee", "白名单命中并行；黑名单命中串行；每个节点一个串行槽；验收固定串行\nTaskPolicy / ExecutionScheduler · 独立租约 / 取消清理 / 不确定清理隔离 · 不保证 GPU 独占"),100,742,1520,105,accent:orange)
c.arrow([(850,865),(850,905)],tint:orange)
c.text(label("Private framed pipes · CLOEXEC · Fixed Host protocol", "私有 framed pipes · CLOEXEC · 固定 Host 协议"),390,876,1000,32,size:18,tint:muted)
c.box(70,914,1580,400,fill:color(0xEFF9F5),stroke:teal)
c.text(label("Native restricted execution / One runtime, two roles", "原生受限执行区 / 一种运行时，两个角色"),95,929,1500,40,size:25,weight:.bold,tint:teal)
c.card(label("Development and task verification instances", "开发与题包验收实例"), label("Separate container/HOME/CLI; concurrent Agent sessions\nClaude / Codex / mini-swe-agent → sandbox-shell → Host\nAgent exit → inject tests → serial verification → save records", "独立容器/HOME/CLI；Agent 主会话并行\nClaude / Codex / mini-swe-agent → sandbox-shell → Host\nAgent 结束 -> 注入 tests -> 串行验收 -> 保存记录"),100,993,740,146,accent:teal)
c.card(label("Evaluation instances", "评测实例"), label("Clean instances created after freezing development artifacts\nSame Host backend and execution queue, not another sandbox\nCandidates do not enter the Verifier process address space", "冻结开发产物后创建的干净实例\n相同 Host 后端 / 执行队列；不是另一套沙箱\n候选不进入 Verifier 进程地址空间"),880,993,740,146,accent:teal)
c.text(label("Public entries compile and run in restricted Host. LaunchServices app launches carry escape risk; trusted code only.", "公开入口在受限 Host 内编译执行；LaunchServices 另起应用存在越界风险，仅运行可信代码。"),110,1160,1490,37,size:21,tint:teal)
c.text(label("Candidate → Metal.framework → MTLDevice / CommandQueue / compute & render pipeline", "候选 -> Metal.framework -> MTLDevice / CommandQueue / compute & render pipeline"),110,1225,1490,38,size:21,weight:.semibold,tint:teal)
c.arrow([(850,1314),(850,1354)],tint:teal)
c.card(label("Physical Apple GPU", "实体 Apple GPU"), label("Native driver/hardware · no partitioning · no control of other Apps' load · CPU exit does not prove GPU drain", "原生驱动与硬件 · 不分区 · 不控制其他应用负载 · CPU 退出不证明 GPU drain"),70,1354,1580,100,accent:orange,titleSize:25,bodySize:21)
c.box(70,1490,1580,145,fill:color(0xFFF9F1),stroke:orange,dash:true)
c.text(label("Capabilities not provided", "未提供的能力"),95,1502,1480,35,size:23,weight:.bold,tint:orange)
c.text(label("Hard resource quotas and GPU recovery certification · full xcodebuild/PTY\nDeveloper ID notarization and comprehensive cross-system verification. Trusted local development only; see README.md release scope.", "资源硬配额与 GPU 恢复认证 · 完整 xcodebuild/PTY\nDeveloper ID 公证与全面跨系统验收。当前仅限可信本地开发；详见 README.md 的版本范围。"),95,1547,1470,76,size:21,tint:muted)
try c.save("architecture.png")
