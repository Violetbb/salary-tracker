import Foundation

@main struct CalculatorChecks {
    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        var c=Calc.cal.dateComponents([.year,.month],from:Date()); c.year=2026;c.month=month;c.day=day;c.hour=hour;c.minute=minute
        return Calc.cal.date(from:c)!
    }
    static func check(_ name:String,_ condition:Bool){if !condition {fputs("FAIL: \(name)\n",stderr);exit(1)};print("PASS: \(name)")}
    static func main() {
        let s=Settings()
        check("正常工作日排程",Calc.planned(at(24,9),settings:s))
        check("午休期間不累積",Calc.scheduledSeconds(from:at(24,9),to:at(24,12,30),settings:s)==10800)
        check("下班後停止",Calc.scheduledSeconds(from:at(24,9),to:at(24,20),settings:s)==28800)
        check("週末休息",!Calc.planned(at(28,10),settings:s) && Calc.secondsToday(now:at(28,10),settings:s)==0)
        check("固定國定日",!Calc.planned(at(10,10,month:10),settings:s))
        var makeup=s; makeup.holidayOverrides[Calc.dateKey(at(28,10))]="workday"
        check("補班覆寫",Calc.planned(at(28,10),settings:makeup))
        var leave=s; leave.leaves=[LeaveEntry(date:at(24,9),start:"10:00",end:"11:00",kind:"事假")]
        check("事假降低工作累積",Calc.workingSeconds(from:at(24,9),to:at(24,12),settings:leave)==7200)
        let annual=LeaveEntry(date:at(24,9),start:"10:00",end:"11:00",kind:"特休")
        let sick=LeaveEntry(date:at(24,9),start:"10:00",end:"11:00",kind:"普通傷病假")
        check("特休不扣薪",Calc.leaveDeduction(annual,settings:s)==0)
        let expectedSick=s.monthlySalary/Calc.monthScheduledSeconds(at(24,10),settings:s)*3600*0.5
        check("病假半薪扣款",abs(Calc.leaveDeduction(sick,settings:s)-expectedSick)<0.01)
        check("跨月月初依實際日期",Calc.monthStart(at(1,10,month:12)) != Calc.monthStart(at(1,10)))
        let baseHourly=(s.monthlySalary-Calc.fixedMonthlyDeductions(at(24,10),settings:s))/(Calc.monthScheduledSeconds(at(24,10),settings:s)/3600)
        var adjusted=s; adjusted.monthlySalary += 2400
        let adjustedHourly=(adjusted.monthlySalary-Calc.fixedMonthlyDeductions(at(24,10),settings:adjusted))/(Calc.monthScheduledSeconds(at(24,10),settings:adjusted)/3600)
        check("修改月薪更新本月時薪",adjustedHourly>baseHourly)
        let asleep=Calc.workingSeconds(from:at(24,9),to:at(24,11),settings:s)
        check("睡眠/關閉後仍由時間重算",asleep==7200)
        let now=at(25,13)
        let elapsed=Calc.scheduledSeconds(from:Calc.monthStart(now),to:now,settings:s)
        let total=Calc.monthScheduledSeconds(now,settings:s)
        let net=s.monthlySalary-Calc.fixedMonthlyDeductions(now,settings:s)
        print("CHECK FIXTURE: month hours=\(total/3600), elapsed hours=\(elapsed/3600), net=\(net), cumulative=\(Calc.cumulativePay(to:now,settings:s))")
        check("本月累積按本月排定工時比例",abs(Calc.cumulativePay(to:now,settings:s)-net*elapsed/total)<0.01)
        check("本月25日不再只有240小時制累積",Calc.cumulativePay(to:now,settings:s)>35000)
        print("All calculator checks passed.")
    }
}
