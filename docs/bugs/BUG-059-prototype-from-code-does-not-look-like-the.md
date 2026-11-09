---
type: bug
id: BUG-059
title: "Prototype from code does not look like the real application: a big widget is reduced to a generic look-alike (OptionDesk TRADE tab)"
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
updated: 2026-11-03
---

# Prototype from code does not look like the real application: a big widget is reduced to a generic look-alike (OptionDesk TRADE tab)

## Summary

The StrikeDesk prototype (broker-fabric, apps/strikedesk) no longer misses the option chain, but its TRADE tab is a generic options table, not the real OptionDesk. Evidence from the recorded run (2026-11-03): the real OptionDesk.tsx is 2102 lines (84 KB) and imports 51 files (519 KB at the first level; ChainTable.tsx alone is 83 KB), while the prototype's trade screen is 9.4 KB written by one assistant call of 35 s (277k input tokens, 3.3k output tokens, effort medium). The screen prompt for an embedded widget already says to read the whole file and every file it imports and not to shorten it to a sample; the assistant did not follow it. Labels checked against the source (case-insensitive): 'Custom (Manual)', 'BP EFF', 'Calls' and 'Puts' are absent from the trade screen, 'Bid (Sell)' and 'Ask (Buy)' occur only as other text in other files (the tab shows 'Bid' and 'Ask'), and the footer labels (Max profit, Max loss) are in the code of the screen but are not visible on the screenshot. The tab shows columns that do not exist in the code (Volume, Open interest), only 4 strike rows, and an unrounded Delta (-0.4499999999999). ChainTable, ChainFilters, OrderTicket, StrategyBuilder and PayoffChart are not among the 27 reproduced components. The seven invented accounts (the real app shows one) and the header chips (Environment, Broker, Data source) also look invented; this is judged from the screenshots only and is not yet checked against the code. The default layout itself matches the code (one group with left tabs; test optionTradingLayout.test.ts): the arrangement in the real screenshot is a saved user layout and is not in the code. Root cause: each screen is written by one assistant call and the app only checks that it renders; nothing compares the visible labels, columns and controls with the screen's source files, so a large widget becomes a look-alike. Measured with a scratch script: the share of visible labels of the source that appear in the screen is 22% for OptionDesk (with its imports), 55% for PositionMonitor and 100% for TradeJournal, so the signal exists but is noisy (dialogs such as ExitBracketPopup add labels that are not visible at start). Chosen approach (Boris, 2026-11-03): verify each built screen against its sources and send what is missing into a repair pass as a list of absent items.

## Steps to reproduce

1. Open the strikedesk prototype in broker-fabric (made from code, 5.10.x).
2. Open the TRADE tab and compare it with the real StrikeDesk Option Trading workspace.

## Expected

The TRADE tab shows the real widget: the same control row (Custom (Manual), GO, CONFIG, expiry, REFRESH), the same chain columns (Delta, Bid (Sell), Ask (Buy), Strike, Bid (Sell), Ask (Buy), Delta), the Calls/Puts header with the expiry and IVx, and the footer metrics (POP, P50, DELTA, THETA, MAX PROFIT, MAX LOSS, BP EFF). Labels and numbers come from the source; nothing is invented, and values are formatted as the code formats them.

## Actual

The TRADE tab is a generic options table (Volume, Open interest, Delta, Bid, Ask, Strike) with four rows, a different control layout and an unrounded Delta (-0.4499999999999). The accounts table and the header chips contain content that is not in the code.

## Environment

MarkView 5.10.x, Prototype Studio code mode, project broker-fabric (apps/strikedesk), assistant: Codex gpt-6.1-terra (medium)

## Fix

Fix (5.11.0). (1) PrototypeFidelity compares the visible labels of each screen's source files (its evidence files plus what they import inside their own folder, one level, without tests, dialogs, menus, editors, previews and the evidence of other screens) with the screen's script; the shared data.js does not count, because it holds the labels of every screen and made the option desk look 51% complete. A screen is thin when its source has 12 or more labels and under 40% are in the script. On the 22 screens of the strikedesk prototype it names two: trade (32%) and settings (9%); the others show 60% to 100%. (2) After a build, a full sync and an incremental sync (rewritten screens only) the session names the thin screens in the chat and gives the thinnest three one repair pass each (PrototypeAI.revise aimed at the screen, with the list of absent labels grouped by source file), then compares again and says what is still thin; when a repair changed the prototype the preview fix round runs once more. (3) A host, widget or modal whose evidence files add up to 40 KB or more is written at high effort instead of medium. Verified: the standalone checks (55 for the new module, 61 embedded), the full prototype suite, a Debug build, and a real Codex run of the repair request on a COPY of the strikedesk prototype: trade.js grew from 9.4 KB to 42.2 KB in 201 s, the share of source labels in the screen went from 32% to 92%, and a headless render shows the real column headers (Vol, Opn Int, ITM %, Delta, Bid (Sell), Ask (Buy), Strike), the Calls | 7d | Puts row, the Table and Analysis tabs, the Custom (Manual) selector, GO and CONFIG, and a formatted Delta. Still different from the real application: no IVx and REFRESH, four strike rows (that is all the sample data has) and the footer metrics bar is not visible. Not covered: the session wiring (messages, version, second preview round) is compiled but has not been run in the app; invented accounts and header chips and the sample data are separate problems. An existing prototype needs Sync with Rebuild everything.
