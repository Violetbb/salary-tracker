import SwiftUI
import AppKit
import ServiceManagement
import IOKit

struct LeaveEntry: Identifiable, Codable {
    var id = UUID(); var date = Date(); var start = "09:00"; var end = "18:00"
    var kind = "特休"; var note = ""
}

struct Settings: Codable {
    var monthlySalary = 46000.0
    var dependents = 0
    var otherDeduction = 0.0
    var start = "09:00"; var end = "18:00"; var lunchStart = "12:00"; var lunchEnd = "13:00"
    var weekdays = [1,2,3,4,5]
    var opacity = 1.0; var alwaysOnTop = false; var dark = false; var size = "標準"
    var launchOnLogin = false
    var holidayOverrides: [String: String] = [:] // date -> holiday / workday
    var leaves: [LeaveEntry] = []
}

@MainActor final class Store: ObservableObject {
    @Published var value: Settings { didSet { save() } }
    private let url: URL
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SalaryTracker", isDirectory: true)
        let id = Self.platformID() ?? Self.localID(in: root)
        let dir = root.appendingPathComponent("devices", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")
        // Import existing local preferences once; each Mac then writes to its own device folder.
        let previous = root.appendingPathComponent("settings.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: previous.path) {
            try? FileManager.default.copyItem(at: previous, to: url)
        }
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Settings.self, from: data) { value = decoded } else { value = Settings() }
    }
    private func save() { if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) } }
    private static func platformID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { return nil }
        return property.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
    private static func localID(in root: URL) -> String {
        let idFile = root.appendingPathComponent("device-id")
        if let id = try? String(contentsOf: idFile, encoding: .utf8), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? id.write(to: idFile, atomically: true, encoding: .utf8)
        return id
    }
}

enum Calc {
    static var taipei: TimeZone { TimeZone(identifier: "Asia/Taipei")! }
    static let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = taipei; return c }()
    static func minute(_ s: String) -> Int { let a = s.split(separator: ":").compactMap { Int($0) }; return a.count == 2 ? a[0]*60+a[1] : 0 }
    static func money(_ x: Double) -> String { "NT$ " + x.formatted(.number.precision(.fractionLength(2))) }
    static func isHoliday(_ date: Date, settings: Settings) -> Bool {
        let key = dateKey(date)
        if settings.holidayOverrides[key] == "workday" { return false }; if settings.holidayOverrides[key] == "holiday" { return true }
        // Static national days; movable lunar holidays are supplied through editable annual overrides.
        let md = cal.dateComponents([.month,.day], from: date)
        let fixed: Set<String> = ["1-1","2-28","4-4","4-5","5-1","9-28","10-10","10-25","12-25"]
        return fixed.contains("\(md.month ?? 0)-\(md.day ?? 0)")
    }
    static func planned(_ date: Date, settings s: Settings) -> Bool {
        if s.holidayOverrides[dateKey(date)] == "workday" { return true }
        return s.weekdays.contains(cal.component(.weekday, from: date)-1) && !isHoliday(date, settings: s)
    }
    static func dateKey(_ date: Date) -> String { let f=DateFormatter(); f.calendar=cal; f.timeZone=taipei; f.dateFormat="yyyy-MM-dd"; return f.string(from:date) }
    static func secondsToday(now: Date, settings s: Settings) -> Double {
        let day = cal.startOfDay(for: now)
        return max(0, cumulativePay(to: now, settings: s) - cumulativePay(to: day, settings: s))
    }
    static func workingSeconds(from: Date, to: Date, settings s: Settings) -> Double {
        max(0, scheduledSeconds(from: from, to: to, settings: s) - s.leaves.reduce(0.0) { $0 + leaveOverlap($1, from: from, to: to) })
    }
    static func scheduledSeconds(from: Date, to: Date, settings s: Settings) -> Double {
        guard to > from else { return 0 }
        var cursor = cal.startOfDay(for: from), total = 0.0
        while cursor < to {
            if planned(cursor, settings: s) {
                let base = cursor.timeIntervalSince1970
                for (a,b) in [(minute(s.start),minute(s.lunchStart)),(minute(s.lunchEnd),minute(s.end))] {
                    let lo = max(from.timeIntervalSince1970, base+Double(a*60)), hi = min(to.timeIntervalSince1970, base+Double(b*60))
                    total += max(0, hi-lo)
                }
            }
            cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
        }
        return total
    }
    static func leaveOverlap(_ leave: LeaveEntry, from: Date, to: Date) -> Double {
        let day=cal.startOfDay(for:leave.date), a=day.addingTimeInterval(Double(minute(leave.start)*60)), b=day.addingTimeInterval(Double(minute(leave.end)*60))
        return max(0,min(to,b).timeIntervalSince1970-max(from,a).timeIntervalSince1970)
    }
    static func monthStart(_ date: Date) -> Date { cal.date(from: cal.dateComponents([.year,.month], from: date))! }
    static func monthWorkdays(_ date: Date, settings s: Settings) -> Int {
        let first = monthStart(date), range = cal.range(of: .day, in: .month, for: date)!
        return range.compactMap { cal.date(byAdding: .day, value: $0-1, to: first) }.filter { planned($0, settings: s) }.count
    }
    static func monthScheduledSeconds(_ date: Date, settings s: Settings) -> Double {
        let first=monthStart(date), next=cal.date(byAdding:.month,value:1,to:first)!
        return scheduledSeconds(from:first,to:next,settings:s)
    }
    static func fixedMonthlyDeductions(_ date: Date, settings s: Settings) -> Double {
        let (labor,employment,health)=insurance(s.monthlySalary,dependents:s.dependents,date:date)
        return labor+employment+health+s.otherDeduction
    }
    static func cumulativePay(to date: Date, settings s: Settings) -> Double {
        let first=monthStart(date), next=cal.date(byAdding:.month,value:1,to:first)!
        let total=monthScheduledSeconds(date,settings:s)
        guard total > 0 else { return 0 }
        let elapsed=min(total,scheduledSeconds(from:first,to:min(date,next),settings:s))
        let rate=max(0,s.monthlySalary-fixedMonthlyDeductions(date,settings:s))/total
        let leaveDeductTotal=s.leaves.filter { cal.isDate($0.date,equalTo:date,toGranularity:.month) && $0.date <= date }
            .reduce(0.0) { $0 + leaveDeduction($1,settings:s,through:date) }
        return max(0,elapsed*rate-leaveDeductTotal)
    }
    static func insurance(_ salary: Double, dependents: Int, date: Date) -> (Double,Double,Double) {
        // Year-specific official parameter set. 2026 values confirmed; 2027 published BLI schedule.
        let year = cal.component(.year, from: date)
        let laborRate = year >= 2027 ? 0.12 : 0.115 // 2026 total 12.5%, less employment insurance 1%
        let employmentRate = 0.01
        let wageFloor = year >= 2027 ? 30900.0 : 28590.0
        let brackets = [wageFloor,30300.0,31800,33300,34800,36300,38200,40100,42000,43900,45800,48200,50600,53000,55400,57800]
        let insured = salary <= wageFloor ? wageFloor : (brackets.first { salary <= $0 } ?? min(salary, 45800))
        let labor = (insured*laborRate*0.2).rounded()
        let employment = (insured*employmentRate*0.2).rounded()
        let health = (insured*0.0517*0.3*Double(min(3, max(0, dependents)+1))).rounded()
        return (labor,employment,health)
    }
    static func leaveDeduction(_ leave: LeaveEntry, settings s: Settings, through cutoff: Date? = nil) -> Double {
        guard leave.kind == "事假" || leave.kind == "普通傷病假" || leave.kind == "其他" else { return 0 }
        let day=cal.startOfDay(for:leave.date)
        let starts=day.addingTimeInterval(Double(minute(leave.start)*60)), ends=day.addingTimeInterval(Double(minute(leave.end)*60))
        let through=cutoff ?? ends
        let intervals=[(minute(s.start),minute(s.lunchStart)),(minute(s.lunchEnd),minute(s.end))]
        let duration=intervals.reduce(0.0) { sum, interval in
            let lo=max(starts,day.addingTimeInterval(Double(interval.0*60))), hi=min(min(ends,through),day.addingTimeInterval(Double(interval.1*60)))
            return sum+max(0,hi.timeIntervalSince(lo))
        }
        let monthlyHours=monthScheduledSeconds(leave.date,settings:s)
        let hourly=monthlyHours > 0 ? s.monthlySalary/monthlyHours*3600 : s.monthlySalary/240
        let fraction = leave.kind == "普通傷病假" ? 0.5 : 1
        return duration/3600*hourly*fraction
    }
}

#if !SALARY_TEST
@main struct SalaryTrackerApp: App {
    @StateObject var store = Store()
    var body: some Scene {
        WindowGroup {
            Dashboard(store: store)
        }
        .defaultSize(width: 340, height: 300)
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
    }
}

struct WindowAccessor: NSViewRepresentable {
    let top: Bool; let opacity: Double
    func makeNSView(context: Context) -> NSView { let v=NSView(); DispatchQueue.main.async { if let w=v.window { Self.configureWindow(w, top: top); w.title="賣命計時器" } }; return v }
    func updateNSView(_ nsView: NSView, context: Context) { DispatchQueue.main.async { if let w=nsView.window { Self.configureWindow(w, top: top) } } }
    static func configureWindow(_ w: NSWindow, top: Bool) {
        w.styleMask.formUnion([.titled, .closable, .miniaturizable])
        w.standardWindowButton(.closeButton)?.isHidden = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = false
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.level = top ? .floating : .normal
        w.isOpaque = false
        w.backgroundColor = .clear
        w.alphaValue = 1
        w.ignoresMouseEvents = false
        w.isMovableByWindowBackground = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize { CGSize(width: 1, height: 1) }
}

struct Dashboard: View {
    @ObservedObject var store: Store
    @State private var now = Date(); @State private var page = "主畫面"; @State private var leaveDate = Date(); @State private var leaveKind = "特休"; @State private var leaveStart="09:00"; @State private var leaveEnd="18:00"; @State private var holidayDate=""; @State private var holidayKind="holiday"
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var s: Settings { store.value }
    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                header
                if page == "主畫面" { main }
                else if page == "設定" { settings }
                else { history }
            }.padding(16)
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius:24).fill(LinearGradient(colors: s.dark ? [Color(red:0.17,green:0.16,blue:0.25),Color(red:0.12,green:0.14,blue:0.21)] : [Color(red:1.00,green:0.97,blue:0.91),Color(red:0.96,green:0.92,blue:1.00)], startPoint:.topLeading,endPoint:.bottomTrailing)).opacity(s.opacity)
                Circle().fill(Color.pink.opacity(s.dark ? 0.08:0.12)).frame(width:130).blur(radius:16).offset(x:145,y:-120)
                Circle().fill(Color.purple.opacity(s.dark ? 0.10:0.10)).frame(width:120).blur(radius:20).offset(x:-150,y:140)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius:24))
        .overlay(RoundedRectangle(cornerRadius:24).stroke(.white.opacity(s.dark ? 0.12:0.72),lineWidth:1))
        .shadow(color:Color.purple.opacity(0.12),radius:18,y:8)
        .frame(width: s.size == "小型" ? 250 : (s.size == "展開" ? 420 : 300), height: s.size == "小型" ? 190 : (s.size == "展開" ? 530 : 255))
        .fixedSize()
        .overlay(alignment: .topLeading) { WindowAccessor(top:s.alwaysOnTop,opacity:s.opacity).frame(width:1,height:1).allowsHitTesting(false) }
        .preferredColorScheme(s.dark ? .dark : .light)
        .foregroundStyle(s.dark ? .white : Color.primary).onReceive(timer) { now=$0; applyWindow() }
    }
    var header: some View {
        HStack(spacing:8) {
            ZStack { Circle().fill(LinearGradient(colors:[Color(red:1,green:0.78,blue:0.55),Color(red:1,green:0.62,blue:0.72)],startPoint:.topLeading,endPoint:.bottomTrailing)); Image(systemName:"sparkles").font(.system(size:14,weight:.bold)).foregroundStyle(.white) }
                .frame(width:30,height:30).shadow(color:.pink.opacity(0.22),radius:5,y:2)
            Text("賣命計時器").font(.system(size:13,weight:.bold,design:.rounded))
            Spacer(minLength:4)
            Button { minimizeAppWindow() } label: { Image(systemName:"minus").font(.system(size:11,weight:.bold)).frame(width:27,height:27).background(.white.opacity(s.dark ? 0.10:0.75),in:Circle()) }
                .buttonStyle(.plain).help("縮到 Dock")
            Menu {
                Button("主畫面",systemImage:"house.fill"){page="主畫面"}
                Button("設定",systemImage:"slider.horizontal.3"){page="設定"}
                Button("本月紀錄",systemImage:"calendar"){page="紀錄"}
            } label: { Image(systemName:page == "設定" ? "gearshape.fill":"ellipsis").font(.system(size:12,weight:.bold)).frame(width:27,height:27).background(.white.opacity(s.dark ? 0.10:0.75),in:Circle()) }
                .menuStyle(.borderlessButton).help("更多")
        }.foregroundStyle(s.dark ? .white : Color(red:0.26,green:0.23,blue:0.31))
    }
    func minimizeAppWindow() {
        let window=NSApp.windows.first(where:{$0.isKeyWindow}) ?? NSApp.windows.first(where:{$0.isMainWindow}) ?? NSApp.windows.first(where:{$0.title == "Salary Tracker" && $0.isVisible})
        window?.miniaturize(nil)
    }
    var main: some View {
        let (labor,emp,health)=Calc.insurance(s.monthlySalary,dependents:s.dependents,date:now)
        let monthHours=Calc.monthScheduledSeconds(now,settings:s)
        let netHourly=monthHours > 0 ? max(0,s.monthlySalary-labor-emp-health-s.otherDeduction)/(monthHours/3600) : 0
        let perSecond=netHourly/3600, today=Calc.secondsToday(now:now,settings:s)
        let month=Calc.cumulativePay(to:now,settings:s)
        return VStack(spacing:16) {
            VStack(spacing:3){Text("今日💰💰").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary);Text(Calc.money(today)).font(.system(size:s.size == "小型" ? 24:30,weight:.bold,design:.rounded).monospacedDigit()).minimumScaleFactor(0.70).lineLimit(1)}
            HStack(spacing:9) { metric("本月賣命收入",Calc.money(month),big:true,icon:"calendar"); if s.size != "小型" { metric("每分鐘",Calc.money(perSecond*60),big:false,icon:"heart.fill") } }
            HStack(spacing:5) { Image(systemName:"clock.fill").foregroundStyle(.pink.opacity(0.8)); Text("\(s.start) — \(s.end)"); Spacer(); Text(Calc.planned(now,settings:s) ? "工作日 ✨" : "休息日 🌷") }.font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)
            if s.size == "展開" {
                Divider(); let net=s.monthlySalary-labor-emp-health-s.otherDeduction-s.monthLeaveDeduction(now:now)
                HStack { Text("本月排定工時"); Spacer(); Text("\(Int(monthHours/3600)) 小時") }
                HStack { Text("本月實領基準時薪 / 分鐘 / 秒"); Spacer(); Text("\(Calc.money(netHourly)) / \(Calc.money(netHourly/60)) / \(Calc.money(netHourly/3600))") }.font(.system(size:10))
                HStack { Text("稅前月薪"); Spacer(); Text(Calc.money(s.monthlySalary)) }
                HStack { Text("勞保 / 就保 / 健保"); Spacer(); Text("− \(Int(labor)) / \(Int(emp)) / \(Int(health))") }
                HStack { Text("預估實領").fontWeight(.semibold); Spacer(); Text(Calc.money(net)).fontWeight(.semibold) }
                Text("估算：2026 官方費率與級距；不含職災保險、所得稅與雇主福利。月薪制工資不因休假日未上班而扣除。").font(.system(size:9)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
    }
    func metric(_ title:String,_ value:String,big:Bool,icon:String)->some View { VStack(alignment:.leading,spacing:5){Label(title,systemImage:icon).font(.system(size:9,weight:.medium)).foregroundStyle(.secondary);Text(value).font(.system(size:big ? 16:15,weight:.bold,design:.rounded).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)}.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,10).padding(.vertical,9).background(.white.opacity(s.dark ? 0.08:0.78),in:RoundedRectangle(cornerRadius:15)).overlay(RoundedRectangle(cornerRadius:15).stroke(.white.opacity(0.66),lineWidth:1)) }
    var settings: some View {
        ScrollView { VStack(alignment:.leading,spacing:11) {
            Text("薪資與工作時間").font(.headline)
            HStack { Text("稅前月薪"); Spacer(); TextField("46000",value:$store.value.monthlySalary,format:.number).frame(width:100).textFieldStyle(.roundedBorder) }
            HStack { Text("健保眷屬"); Spacer(); Stepper("\(s.dependents)",value:$store.value.dependents,in:0...3).frame(width:125) }
            HStack { Text("其他月扣款"); Spacer(); TextField("0",value:$store.value.otherDeduction,format:.number).frame(width:100).textFieldStyle(.roundedBorder) }
            Grid(alignment:.leading,horizontalSpacing:10,verticalSpacing:6){GridRow{Text("上班");TextField("09:00",text:$store.value.start);Text("下班");TextField("18:00",text:$store.value.end)};GridRow{Text("午休");TextField("12:00",text:$store.value.lunchStart);Text("至");TextField("13:00",text:$store.value.lunchEnd)}}.textFieldStyle(.roundedBorder)
            HStack { ForEach(1...7,id:\.self){ d in Toggle(["日","一","二","三","四","五","六"][d-1],isOn:Binding(get:{s.weekdays.contains(d-1)},set:{on in if on {if !store.value.weekdays.contains(d-1){store.value.weekdays.append(d-1)}} else {store.value.weekdays.removeAll{$0==d-1}}})).toggleStyle(.button).controlSize(.small) } }
            Divider(); Text("外觀與年度日曆").font(.headline)
            Picker("視窗",selection:$store.value.size){Text("小型").tag("小型");Text("標準").tag("標準");Text("展開").tag("展開")}.pickerStyle(.segmented)
            Toggle("深色模式",isOn:$store.value.dark); Toggle("視窗置頂",isOn:$store.value.alwaysOnTop)
            Toggle("登入時啟動",isOn:Binding(get:{s.launchOnLogin},set:{enabled in store.value.launchOnLogin=enabled; if enabled {try? SMAppService.mainApp.register()} else {try? SMAppService.mainApp.unregister()} }))
            HStack { Text("透明度"); Slider(value:$store.value.opacity,in:0.65...1) }
            HStack { TextField("YYYY-MM-DD",text:$holidayDate); Picker("類型",selection:$holidayKind){Text("假日").tag("holiday");Text("補班").tag("workday")}.frame(width:85); Button("新增"){store.value.holidayOverrides[holidayDate]=holidayKind;holidayDate=""} }
            Text("政府年度行事曆可在此手動維護浮動節日與補班日；固定國定日已內建。尚未連接自動更新服務。").font(.system(size:9)).foregroundStyle(.secondary)
            Divider(); Text("請假管理").font(.headline)
            DatePicker("日期",selection:$leaveDate,displayedComponents:.date)
            HStack { Picker("假別",selection:$leaveKind){ForEach(["特休","事假","普通傷病假","其他"],id:\.self){Text($0)}}; TextField("開始",text:$leaveStart);TextField("結束",text:$leaveEnd) }
            Button("新增請假紀錄") { store.value.leaves.append(LeaveEntry(date:leaveDate,start:leaveStart,end:leaveEnd,kind:leaveKind)) }
            ForEach(store.value.leaves) { l in HStack{Text(l.date.formatted(date:.numeric,time:.omitted));Text(l.kind);Text(l.start+"–"+l.end).foregroundStyle(.secondary);Spacer();Button(role:.destructive){store.value.leaves.removeAll{$0.id==l.id}}label:{Image(systemName:"trash")} } }
        }.font(.system(size:11)).textFieldStyle(.roundedBorder) }.frame(maxHeight:440)
    }
    var history: some View {
        let (labor,emp,health)=Calc.insurance(s.monthlySalary,dependents:s.dependents,date:now)
        let deduction=s.monthLeaveDeduction(now:now)
        return VStack(alignment:.leading,spacing:10){Text(now.formatted(.dateTime.year().month())).font(.title3.bold());HStack{Text("本月累積實領");Spacer();Text(Calc.money(Calc.cumulativePay(to:now,settings:s)))};HStack{Text("本月排定工時");Spacer();Text("\(Int(Calc.monthScheduledSeconds(now,settings:s)/3600)) 小時")};HStack{Text("本月請假扣款");Spacer();Text("− "+Calc.money(deduction))};HStack{Text("月實領預估");Spacer();Text(Calc.money(s.monthlySalary-labor-emp-health-s.otherDeduction-deduction))};Text("本月累積 = 預估實領 ÷ 本月排定工時 × 已經過排定工時，再扣已發生的扣薪假。") .font(.system(size:10)).foregroundStyle(.secondary);Spacer()}.font(.system(size:12))
    }
    func applyWindow(){ if let w=NSApp.windows.first(where:{$0.isVisible && $0.contentView != nil}) { WindowAccessor.configureWindow(w, top:s.alwaysOnTop) } }
}

extension Settings {
    func monthLeaveDeduction(now:Date)->Double { leaves.filter{Calc.cal.isDate($0.date,equalTo:now,toGranularity:.month)}.reduce(0){$0+Calc.leaveDeduction($1,settings:self)} }
}
#endif
