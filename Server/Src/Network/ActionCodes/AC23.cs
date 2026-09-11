using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using DataFiles;
using Game;
using Game.Code;
using Game.Maps;
using Game.PlayerRelated;
using Network;
using wlo.pserver.core.Game;

namespace Network.ActionCodes
{
    public class AC23 : AC
    {
        public override int ID { get { return 23; } }

        public override void ProcessPkt(Player r, RecievePacket p)
        {
            p.SetPtr(6);
            switch (p.B)
            {
                case 2: Recv2(r, p); break;       // Get item from ground
                case 3: Recv3(r, p); break;       // Drop item to ground
                case 10: Recv10(r, p); break;     // Move inventory item
                case 11: Recv11(r, p); break;     // Equip
                case 12: Recv12(r, p); break;     // Unequip
                case 14: Recv14(r, p); break;     // Compound synthesis
                case 15: Recv15(r, p); break;     // Quick HP/SP refill / tent
                case 25: Recv25(r, p); break;     // IM balance
                case 26: Recv26(r, p); break;     // Direct Item Mall buy
                case 54: Recv54(r, p); break;     // Item Mall catalog
                case 77: Recv77(r, p); break;     // Player stall list
                case 96: RecvUseItem(r, p, 96); break;   // Older client variant
                case 128: RecvUseItem(r, p, 128); break; // Rhode Island double-click/use
                case 124: Recv124(r, p); break;    // Confirm destroy
                default:
                    DebugSystem.Write($"AC {p.A},{p.B} has not been coded");
                    break;
            }
        }

        private static void SendItemMessage(Player p, string message)
        {
            if (p == null || string.IsNullOrWhiteSpace(message)) return;
            p.Send(Tools.FromFormat("bbbs", 23, 57, 0, message));
        }

        private static string GetItemName(InvItem item, ushort itemId)
        {
            if (item != null && !string.IsNullOrWhiteSpace(item.Name))
                return item.Name.Trim('\0', ' ');
            return $"Item #{itemId}";
        }

        /// <summary>
        /// Reads HP/SP recovery values from Item.dat. The range fallbacks are retained only
        /// for known legacy food/potion groups; unknown items are never consumed as food.
        /// </summary>
        private static bool TryGetRecovery(ushort itemId, DataFiles.PhxItemInfo itemInfo, out int hpGain, out int spGain)
        {
            hpGain = 0;
            spGain = 0;

            // Fugu Hot Pot (starter item #32176): HP +300 / SP +300.
            if (itemId == 32176)
            {
                hpGain = 300;
                spGain = 300;
                return true;
            }

            if (itemInfo != null && itemInfo.StatusType != null && itemInfo.StatusUp != null)
            {
                int len = Math.Min(itemInfo.StatusType.Length, itemInfo.StatusUp.Length);
                for (int i = 0; i < len; i++)
                {
                    if (itemInfo.StatusType[i] == 207) hpGain += itemInfo.StatusUp[i];
                    else if (itemInfo.StatusType[i] == 208) spGain += itemInfo.StatusUp[i];
                }
            }

            if (hpGain == 0 && spGain == 0)
            {
                if (itemId >= 28001 && itemId <= 28050)
                {
                    hpGain = 60;
                    spGain = 40;
                }
                else if (itemId >= 30201 && itemId <= 30210)
                {
                    hpGain = 150;
                    spGain = 80;
                }
                else if (itemId >= 23001 && itemId <= 23060)
                {
                    hpGain = 100;
                    spGain = 100;
                }
            }

            return hpGain > 0 || spGain > 0;
        }

        /// <summary>
        /// WLO Potential levels are cumulative bonuses to all five base attributes.
        /// Level 1-4 add one point on each successful step; 5-12 add 2..9 respectively.
        /// Until the authentic Rhode Island failure-rate table is captured, this emulator
        /// uses safe-success mode so a valid pill cannot disappear without applying an effect.
        /// </summary>
        private static bool UsePotentialPill(Player p, byte slot, string itemName)
        {
            if (p == null) return false;

            int current = p.Potential;
            if (current >= 12)
            {
                SendItemMessage(p, "Potential is already at the maximum level (12).");
                return true;
            }

            int next = current + 1;
            int delta = next <= 4 ? 1 : next - 3;

            p.baseStr = (ushort)Math.Min(ushort.MaxValue, p.baseStr + delta);
            p.baseCon = (ushort)Math.Min(ushort.MaxValue, p.baseCon + delta);
            p.baseInt = (ushort)Math.Min(ushort.MaxValue, p.baseInt + delta);
            p.baseWis = (ushort)Math.Min(ushort.MaxValue, p.baseWis + delta);
            p.baseAgi = (ushort)Math.Min(ushort.MaxValue, p.baseAgi + delta);
            p.Potential = (ushort)next;

            p.Inv.RemoveItem(slot, 1);
            p.Eqs?.Send8_1();
            p.SaveCharacterData();

            SendItemMessage(p, $"{itemName} succeeded! Potential {current} -> {next}; STR/CON/INT/WIS/AGI +{delta}.");
            DebugSystem.Write($"[AC23.UseItem] {p.CharName} used Potential Pill #{34269}: Potential {current}->{next}, all base stats +{delta}.");
            return true;
        }

        private void RecvUseItem(Player p, RecievePacket r, byte subCode)
        {
            try
            {
                byte slot;
                try { slot = r.Unpack8(); }
                catch
                {
                    DebugSystem.Write($"[AC23.UseItem] Malformed AC23:{subCode} from {p?.CharName ?? "Unknown"}: missing inventory slot.");
                    return;
                }

                if (slot < 1 || slot > 50)
                {
                    DebugSystem.Write($"[AC23.UseItem] Invalid slot {slot} from {p?.CharName ?? "Unknown"} (AC23:{subCode}).");
                    return;
                }

                var item = p.Inv[slot];
                if (item == null || item.ItemID == 0)
                {
                    DebugSystem.Write($"[AC23.UseItem] Empty slot {slot} from {p.CharName} (AC23:{subCode}).");
                    p.Inv.SendFullSync();
                    return;
                }

                ushort itemId = item.ItemID;
                string itemName = GetItemName(item, itemId);
                var itemInfo = cGlobal.ItemDatManager?.GetItemByID(itemId);

                // Tent
                if (itemId == 36002 || item.Type == eItemType.Tent)
                {
                    p.Tent.Open();
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} opened tent from slot {slot}.");
                    return;
                }

                // Equipable items should equip rather than be consumed.
                if (itemInfo != null && itemInfo.Equippos > 0)
                {
                    p.WearEQ(slot);
                    p.SaveCharacterData();
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} equipped {itemName} (#{itemId}) from slot {slot}.");
                    return;
                }

                // 10X Holy EXP Potion (#34190): 10x EXP for two hours.
                if (itemId == 34190)
                {
                    if (p.Eqs == null)
                    {
                        SendItemMessage(p, "Unable to activate the EXP potion right now; the item was not consumed.");
                        return;
                    }

                    p.Eqs.SetExpMultiplier(10.0, TimeSpan.FromHours(2));
                    p.Inv.RemoveItem(slot, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, "10X Holy EXP Potion activated: EXP x10 for 2 hours.");
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} activated 10X Holy EXP Potion (#34190) for 2 hours.");
                    return;
                }

                // Training Ticket (#34258): enter Training Island.
                if (itemId == 34258)
                {
                    if (p.Level < 1 || p.Level > 199)
                    {
                        SendItemMessage(p, "Training Tickets can only be used from level 1 to 199.");
                        return;
                    }
                    if (p.CurMap == null)
                    {
                        SendItemMessage(p, "Training Island is unavailable right now; the ticket was not consumed.");
                        return;
                    }

                    WarpData warp = new WarpData
                    {
                        DstMap = 13050,
                        DstX_Axis = 100,
                        DstY_Axis = 100
                    };

                    p.CurMap.Teleport(TeleportType.CmD, p, 0, warp);
                    p.Inv.RemoveItem(slot, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, "Training Ticket used. Welcome to Training Island!");
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} used Training Ticket (#34258) and warped to map 13050.");
                    return;
                }

                // WLO SPECIAL CONSUMABLES - STANDARD USE PATH
                // 10X Holy EXP Potion (#34190): 10x EXP for two hours.
                if (itemId == 34190)
                {
                    if (p.Eqs == null)
                    {
                        SendItemMessage(p, "Unable to activate the EXP potion right now; the item was not consumed.");
                        return;
                    }

                    p.Eqs.SetExpMultiplier(10.0, TimeSpan.FromHours(2));
                    p.Inv.RemoveItem(slot, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, "10X Holy EXP Potion activated: EXP x10 for 2 hours.");
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} activated 10X Holy EXP Potion (#34190) for 2 hours.");
                    return;
                }

                // Training Ticket. Both IDs have appeared in Rhode Island client data/logs.
                if (itemId == 34253 || itemId == 34258)
                {
                    if (p.Level < 1 || p.Level > 199)
                    {
                        SendItemMessage(p, "Training Tickets can only be used from level 1 to 199.");
                        return;
                    }
                    if (p.CurMap == null)
                    {
                        SendItemMessage(p, "Training Island is unavailable right now; the ticket was not consumed.");
                        return;
                    }

                    WarpData warp = new WarpData
                    {
                        DstMap = 13050,
                        DstX_Axis = 100,
                        DstY_Axis = 100
                    };

                    p.CurMap.Teleport(TeleportType.CmD, p, 0, warp);
                    p.Inv.RemoveItem(slot, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, "Training Ticket used. Welcome to Training Island!");
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} used Training Ticket (#{itemId}) and warped to map 13050.");
                    return;
                }

                // Potential Pill
                if (itemId == 34269)
                {
                    UsePotentialPill(p, slot, itemName);
                    return;
                }

                // Star currency is intentionally not consumed by double-click.
                if (itemId == 30025)
                {
                    SendItemMessage(p, "Stars are special quest tokens used for skill learning, resets, and rebirth quests.");
                    return;
                }

                // Data-driven HP/SP consumables.
                if (TryGetRecovery(itemId, itemInfo, out int hpGain, out int spGain))
                {
                    if (p.Eqs != null)
                    {
                        p.Eqs.CurHP = Math.Min(p.Eqs.FullHP, p.Eqs.CurHP + hpGain);
                        p.Eqs.CurSP = Math.Min(p.Eqs.FullSP, p.Eqs.CurSP + spGain);
                        p.Eqs.Send8_1();
                    }

                    p.Inv.RemoveItem(slot, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, $"Used {itemName}! Recovered {hpGain} HP and {spGain} SP.");
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} consumed {itemName} (#{itemId}) at slot {slot}: +{hpGain} HP, +{spGain} SP.");
                    return;
                }

                // Do NOT fake-success and delete unknown items. This preserves the item while
                // giving us a precise diagnostic to add its authentic handler.
                string typeText = itemInfo != null ? itemInfo.ItemType.ToString() : "missing Item.dat";
                SendItemMessage(p, $"{itemName} is not implemented by the server yet; the item was not consumed.");
                DebugSystem.Write($"[ITEM UNSUPPORTED] Player={p.CharName} Slot={slot} ItemID={itemId} Name='{itemName}' ItemType={typeText} SubCode={subCode}");
            }
            catch (Exception t)
            {
                DebugSystem.Write($"[AC23.UseItem] Error: {t.Message}\n{t.StackTrace}");
                try { p?.Inv?.SendFullSync(); } catch { }
            }
        }

        void Recv54(Player p, RecievePacket r)
        {
            try
            {
                ItemMallManager.SendCatalog(p, isBonus: false);
                ItemMallManager.SendCatalog(p, isBonus: true);
                ItemMallManager.SendPointBalance(p);
                DebugSystem.Write($"[AC23.Recv54] Item Mall catalogs and balance dispatched to {p.CharName}");
            }
            catch (Exception t) { DebugSystem.Write(new ExceptionData(t)); }
        }

        public static void SendCatalog(Player p)
        {
            Game.PlayerRelated.ItemMallManager.SendCatalog(p);
        }

        void Recv77(Player p, RecievePacket r)
        {
            try
            {
                SendPacket pkt = new SendPacket();
                pkt.Pack8(23);
                pkt.Pack8(4);
                pkt.Pack8(0);
                p.Send(pkt);

                SendPacket endPkt = new SendPacket();
                endPkt.Pack8(23);
                endPkt.Pack8(102);
                p.Send(endPkt);

                DebugSystem.Write($"[AC23.Recv77] Sent empty stall list to {p.CharName}");
            }
            catch (Exception t) { DebugSystem.Write(new ExceptionData(t)); }
        }

        private static void RefreshItemMallBalance(Player p)
        {
            try
            {
                if (p?.UserAccount == null || p.UserAccount.DataBaseID == 0 || cGlobal.gUserDataBase == null)
                    return;

                int dbPoints = cGlobal.gUserDataBase.GetIMPoints(p.UserAccount.DataBaseID);
                p.UserAccount.IM = Math.Max(0, dbPoints);
                DebugSystem.Write($"[ItemMall] Refreshed IM balance for {p.CharName}: {p.UserAccount.IM} points (UserID {p.UserAccount.DataBaseID}).");
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[ItemMall] Could not refresh IM balance for {p?.CharName ?? "Unknown"}: {ex.Message}");
            }
        }
        void Recv25(Player p, RecievePacket r)
        {
            try { RefreshItemMallBalance(p); ItemMallManager.SendPointBalance(p); }
            catch (Exception t) { DebugSystem.Write(new ExceptionData(t)); }
        }

        void Recv26(Player p, RecievePacket r)
        {
            try
            {
                ushort itemId = r.Unpack16();
                byte count = 1;
                try { count = r.Unpack8(); } catch { count = 1; }
                if (count == 0) count = 1;

                // Refresh from users.IM first, then resolve the exact advertised bundle row.
                RefreshItemMallBalance(p);
                bool success = ItemMallManager.PurchaseAdvertisedItem(p, itemId, count);
                if (success)
                    p.SaveCharacterData();
            }
            catch (Exception t) { DebugSystem.Write(new ExceptionData(t)); }
        }

        void Recv1(Player p, RecievePacket r)
        {
        }

        void Recv2(Player p, RecievePacket r)
        {
            try
            {
                byte pos = r.Unpack8();
                ((GameMap)p.CurMap).onItemPickup(p, pos);
                p.SaveCharacterData();
            }
            catch (Exception t) { DebugSystem.Write(new ExceptionData(t)); }
        }

        void Recv3(Player p, RecievePacket r)
        {
            try
            {
                byte pos = r.Unpack8();
                byte qnt = r.Unpack8();
                byte ukn = r.Unpack8();
                if (pos < 1 || pos > 50 || qnt == 0) return;

                var item = p.Inv[pos];
                if (item == null || item.ItemID == 0) return;

                if (item.Dropable)
                {
                    ((GameMap)p.CurMap).onItemDrop(p, pos, qnt);
                    p.SaveCharacterData();
                }
                else
                {
                    SendPacket s = new SendPacket();
                    s.PackArray(new byte[] { 23, 212, 255 });
                    s.Pack8(pos);
                    s.Pack16(item.ItemID);
                    s.Pack8(qnt);
                    p.Send(s);
                }
            }
            catch (Exception t) { DebugSystem.Write(new ExceptionData(t)); }
        }

        void Recv10(Player p, RecievePacket r)
        {
            try
            {
                byte src = r.Unpack8();
                byte ammt = r.Unpack8();
                byte dst = r.Unpack8();

                if (src > 0 && src < 51 && dst > 0 && dst < 51 && ammt > 0 && ammt <= 50)
                {
                    p.Inv.MoveItem(src, dst, ammt);
                    p.SaveCharacterData();
                }
            }
            catch (Exception t) { DebugSystem.Write(new ExceptionData(t)); }
        }

        void Recv11(Player p, RecievePacket r)
        {
            try
            {
                byte loc = r.Unpack8();
                if (loc > 0 && loc < 51)
                {
                    p.WearEQ(loc);
                    p.SaveCharacterData();
                }
            }
            catch (Exception t) { DebugSystem.Write(new ExceptionData(t)); }
        }

        void Recv12(Player p, RecievePacket r)
        {
            try
            {
                byte loc = r.Unpack8();
                byte dst = r.Unpack8();
                if (loc > 0 && loc < 7 && dst > 0 && dst < 51)
                {
                    p.unWearEQ(loc, dst);
                    p.SaveCharacterData();
                }
            }
            catch (Exception t) { DebugSystem.Write(new ExceptionData(t)); }
        }

        /// <summary>
        /// AC23:14 compound synthesis. The result insertion packet layout is also used by
        /// Inventory.SendSlotState so all item creation paths agree on AC23:8.
        /// </summary>
        void Recv14(Player p, RecievePacket r)
        {
            try
            {
                byte count = r.Unpack8();
                if (count < 2) return;
                byte slot1 = r.Unpack8();
                byte slot2 = r.Unpack8();

                if (slot1 < 1 || slot1 > 50 || slot2 < 1 || slot2 > 50 || slot1 == slot2) return;

                var item1 = p.Inv[slot1];
                var item2 = p.Inv[slot2];
                if (item1 == null || item1.ItemID == 0 || item2 == null || item2.ItemID == 0) return;

                ushort id1 = item1.ItemID;
                ushort id2 = item2.ItemID;

                var recipe = Game.Crafting.AlchemyManager.FindRecipe(id1, id2);
                ushort resultItemId = recipe != null
                    ? recipe.OutputItem
                    : (id1 == id2 ? id1 : (ushort)Math.Max(id1, id2));

                var baseItem = cGlobal.ItemDatManager?.GetItemByID(resultItemId);
                if (baseItem == null)
                {
                    SendItemMessage(p, $"Compound result #{resultItemId} is missing from Item.dat. Ingredients were not consumed.");
                    DebugSystem.Write($"[AC23.Recv14] Rejected compound result #{resultItemId}: missing Item.dat entry.");
                    return;
                }

                byte targetSlot = Math.Min(slot1, slot2);

                p.Inv.RemoveItem(slot1, 1);
                p.Inv.RemoveItem(slot2, 1);

                var resultItem = new InvItem();
                resultItem.CopyFrom(baseItem);
                resultItem.Ammt = 1;
                int added = p.Inv.AddItem(resultItem, targetSlot, true);
                if (added != 1)
                {
                    DebugSystem.Write($"[AC23.Recv14] Could not insert compound result #{resultItemId} into slot {targetSlot}.");
                    p.Inv.SendFullSync();
                    return;
                }

                SendPacket s13 = new SendPacket();
                s13.Pack8(23);
                s13.Pack8(13);
                s13.Pack16(resultItemId);
                s13.Pack8(1);
                s13.Pack8(targetSlot);
                p.Send(s13);

                SendPacket s122 = new SendPacket();
                s122.Pack8(23);
                s122.Pack8(122);
                s122.Pack32(p.CharID);
                p.CurMap?.Broadcast(s122);

                p.SaveCharacterData();
                DebugSystem.Write($"[AC23.Recv14] {p.CharName} compounded slot {slot1} (#{id1}) + slot {slot2} (#{id2}) -> #{resultItemId} at slot {targetSlot}");
            }
            catch (Exception t)
            {
                DebugSystem.Write(new ExceptionData(t));
                try { p?.Inv?.SendFullSync(); } catch { }
            }
        }

        /// <summary>
        /// AC23:15 quick HP/SP refill / tent. Unknown items are rejected rather than being
        /// treated as a fake +50/+50 consumable.
        /// </summary>
        void Recv15(Player p, RecievePacket r)
        {
            try
            {
                byte pos = r.Unpack8();
                byte count = 1;
                try { count = r.Unpack8(); } catch { count = 1; }
                if (count == 0) count = 1;

                ushort target = 0;
                try { target = r.Unpack16(); } catch { target = 0; }

                if (pos < 1 || pos > 50) return;
                var item = p.Inv[pos];
                if (item == null || item.ItemID == 0) return;

                if (item.ItemID == 36002 || item.Type == eItemType.Tent)
                {
                    p.Tent.Open();
                    return;
                }

                var itemInfo = cGlobal.ItemDatManager?.GetItemByID(item.ItemID);

                // WLO SPECIAL CONSUMABLES - AC23:15 PATH
                if (item.ItemID == 34190)
                {
                    if (p.Eqs == null)
                    {
                        SendItemMessage(p, "Unable to activate the EXP potion right now; the item was not consumed.");
                        return;
                    }

                    p.Eqs.SetExpMultiplier(10.0, TimeSpan.FromHours(2));
                    p.Inv.RemoveItem(pos, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, "10X Holy EXP Potion activated: EXP x10 for 2 hours.");
                    DebugSystem.Write($"[AC23.Recv15] {p.CharName} activated 10X Holy EXP Potion (#34190) for 2 hours.");
                    return;
                }

                if (item.ItemID == 34253 || item.ItemID == 34258)
                {
                    if (p.Level < 1 || p.Level > 199)
                    {
                        SendItemMessage(p, "Training Tickets can only be used from level 1 to 199.");
                        return;
                    }
                    if (p.CurMap == null)
                    {
                        SendItemMessage(p, "Training Island is unavailable right now; the ticket was not consumed.");
                        return;
                    }

                    WarpData warp = new WarpData
                    {
                        DstMap = 13050,
                        DstX_Axis = 100,
                        DstY_Axis = 100
                    };

                    p.CurMap.Teleport(TeleportType.CmD, p, 0, warp);
                    p.Inv.RemoveItem(pos, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, "Training Ticket used. Welcome to Training Island!");
                    DebugSystem.Write($"[AC23.Recv15] {p.CharName} used Training Ticket (#{item.ItemID}) and warped to map 13050.");
                    return;
                }

                if (item.ItemID == 34269)
                {
                    UsePotentialPill(p, pos, GetItemName(item, item.ItemID));
                    return;
                }

                if (!TryGetRecovery(item.ItemID, itemInfo, out int hpGain, out int spGain))
                {
                    SendItemMessage(p, $"{GetItemName(item, item.ItemID)} cannot be used as an HP/SP refill item.");
                    DebugSystem.Write($"[ITEM UNSUPPORTED] AC23:15 Player={p.CharName} Slot={pos} ItemID={item.ItemID} Name='{GetItemName(item, item.ItemID)}'");
                    return;
                }

                byte useCount = (byte)Math.Min(item.Ammt, count);
                if (useCount == 0) return;

                if (target == 0)
                {
                    if (p.Eqs != null)
                    {
                        p.Eqs.CurHP = Math.Min(p.Eqs.FullHP, p.Eqs.CurHP + hpGain * useCount);
                        p.Eqs.CurSP = Math.Min(p.Eqs.FullSP, p.Eqs.CurSP + spGain * useCount);
                        p.Eqs.Send8_1();
                    }
                    p.Send(Tools.FromFormat("bbdw", 5, 1, p.CharID, (ushort)(p.Eqs != null ? p.Eqs.CurHP : 0)));
                }
                else if (p.PlayerPets != null)
                {
                    byte petSlot = (byte)target;
                    Player.PlayerPetData pet = null;
                    if (p.PlayerPets.TryGetValue(petSlot, out var pPet)) pet = pPet;
                    else if (petSlot > 0 && p.PlayerPets.TryGetValue((byte)(petSlot - 1), out var pPet0)) pet = pPet0;
                    else if (p.PlayerPets.Values.Any(x => x.IsBattle)) pet = p.PlayerPets.Values.FirstOrDefault(x => x.IsBattle);

                    if (pet == null)
                    {
                        SendItemMessage(p, "The selected pet could not be found; item was not consumed.");
                        return;
                    }

                    pet.HP = Math.Min(pet.MaxHP, pet.HP + hpGain * useCount);
                    pet.SP = Math.Min(pet.MaxSP, pet.SP + spGain * useCount);
                    p.Send(Tools.FromFormat("bbbbdd", 8, 2, 25, petSlot, (uint)pet.HP, 0));
                    p.Send(Tools.FromFormat("bbbbdd", 8, 2, 26, petSlot, (uint)pet.SP, 0));
                    p.Send(Tools.FromFormat("bbdw", 5, 1, pet.PetID, (ushort)pet.HP));
                }

                p.Inv.RemoveItem(pos, useCount);
                p.SaveCharacterData();
                DebugSystem.Write($"[AC23.Recv15] Quick refill by {p.CharName}: Slot {pos}, Target {target}, Count {useCount}, +{hpGain * useCount} HP, +{spGain * useCount} SP");
            }
            catch (Exception t)
            {
                DebugSystem.Write(new ExceptionData(t));
                try { p?.Inv?.SendFullSync(); } catch { }
            }
        }

        void Recv124(Player p, RecievePacket r)
        {
            try
            {
                byte pos = r.Unpack8();
                byte qnt = r.Unpack8();
                byte ukn = r.Unpack8();
                if (pos < 1 || pos > 50 || qnt == 0) return;

                var item = p.Inv[pos];
                if (item == null || item.ItemID == 0) return;

                SendPacket s = new SendPacket();
                s.PackArray(new byte[] { 23, 26 });
                s.Pack16(item.ItemID);
                s.Pack8(qnt);
                p.Send(s);

                p.Inv.RemoveItem(pos, qnt);
                p.SaveCharacterData();
            }
            catch (Exception t) { DebugSystem.Write(new ExceptionData(t)); }
        }
    }
}