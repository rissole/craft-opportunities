# Craft Opportunities

## 2.6.1

- With TradeSkillMaster, Refresh now picks up a price Auctionator recorded from a single item search. Before, TSM
  kept the old Auctionator price until a full scan.
- Calculating is faster: TSM's craft value overrides are read once per calculation, and more of each frame is used.
- Reopening the window keeps prices from the last few minutes, unless Auctionator has recorded a new price since.

## 2.6.0

First public release.

- Lists profitable crafts across all of your characters: recipes each one knows, and recipes it has the skill to
  learn, with material cost, estimated proceeds, profit and return on materials.
- Reads recipes and learned recipes through SkillUp Forever's addon API (SkillUp Forever v1.12.0 or later).
- Prices through TradeSkillMaster when it is installed, matching TSM's own crafting cost and profit by default, and
  otherwise by SkillUp Forever's rules with Auctionator's prices.
