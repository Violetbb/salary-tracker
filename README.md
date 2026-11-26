# Salary Tracker 薪水計算器

原生 macOS SwiftUI 桌面小工具。無網路、無帳號。設定以 JSON 儲存在本機 `~/Library/Application Support/SalaryTracker/devices/<本機識別碼>/settings.json`；每台 Mac 使用自己的資料夾，設定不會透過 App 同步。舊版設定會在該台 Mac 首次升級時匯入一次。

## 建置與啟動

需要 macOS 13 或更新版本與 Xcode Command Line Tools。

```sh
xcodebuild -project SalaryTracker.xcodeproj -scheme SalaryTracker -configuration Release -derivedDataPath work/DerivedData build
open outputs/SalaryTracker.app
```

可安裝產物：`outputs/SalaryTracker.app`、`outputs/SalaryTracker.dmg`。提供 Apple Silicon 與 Intel 版本。拖曳 DMG 內 App 至「應用程式」資料夾。此版本尚未以 Apple Developer ID 簽署及公證；首次開啟需在 Finder 對 App 按右鍵選「打開」，再確認一次。正式公證版需 Apple Developer 帳號與 Developer ID Application 憑證。

## 計算與資料說明

- 使用 Asia/Taipei 時區，以目前真實時間與排班區間重算，不靠累計計時器；午休不計薪、請假區段不累計。
- 本月累積按「本月預估實領薪資 ÷ 本月排定總工時 × 已經過排定工時」計算；保費與其他固定扣款按工時比例計入，扣薪假在發生後扣除。時薪會隨本月排班總工時變動，不採固定 240 小時或除以 30/31 天。
- 勞保普通事故、就保、健保僅為受僱者個人負擔估算，未包含職災保險、所得稅或薪資單上的其他項目。
- 2026 官方勞保普通事故費率 12.5%（含就保 1%），個人負擔比例 20%；就保 1%、個人負擔 20%；健保 5.17%、個人負擔 30%。官方資料來源見 BLI 與 NHI 網站。
- 固定國定日已內建；農曆年節、政府公告補班與年度特殊放假日請在設定中輸入 `YYYY-MM-DD`，選擇假日或補班。此版本不會連網自動抓取政府年度行事曆。
- 特休不扣款；事假全額時薪扣款；普通傷病假以半薪估算。請假以起訖時間輸入，記錄留在本機。
- 請假扣薪為簡化估算，法規適用、投保級距與實際薪資單可能依個人投保資料、雇主制度及當年度規則不同，請以官方試算與薪資單為準。

## 回歸檢查

```sh
swiftc -D SALARY_TEST -module-cache-path work/module-cache SalaryTracker.swift work/CalculatorChecks.swift -o work/calculator-checks
work/calculator-checks
```
