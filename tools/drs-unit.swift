import Foundation
// 20 号 DRS 控制器五断言: 基线/热压/不越限/热态更深降/恢复
var drs = DRSController(budgetMs: 16.6)
for _ in 0..<40 { drs.update(frameMs: 8) }
let base = drs.scale == 1.0
drs.setThermal(2)
let cap = drs.scale == 0.7
for _ in 0..<200 { drs.update(frameMs: 5) }
let noClimb = drs.scale <= 0.7
for _ in 0..<60 { drs.update(frameMs: 33) }
let deeper = drs.scale == 0.5
drs.setThermal(0)
for _ in 0..<200 { drs.update(frameMs: 5) }
let rec = drs.scale == 1.0
print("基线:\(base) 热压:\(cap) 不越限:\(noClimb) 热态更深降:\(deeper) 恢复:\(rec)")
exit(base && cap && noClimb && deeper && rec ? 0 : 1)
