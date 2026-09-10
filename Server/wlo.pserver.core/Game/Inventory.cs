using System;
using System.Collections.Generic;
using System.Collections;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using DataFiles;
using Network;
using RCLibrary.Core.Networking;

namespace Game.Code
{
    public class Inventory
    {
        global::DataFiles.PhxItemDat ItemDat;

        Player owner;
        private readonly object mylock;
        private InvItem[] m_Items;

        public Inventory(Player src, global::DataFiles.PhxItemDat ItemDat)
        {
            owner = src;
            this.ItemDat = ItemDat;
            mylock = new object();
            m_Items = new InvItem[50];
            for (int a = 0; a < 50; a++)
                m_Items[a] = new InvItem();
        }

        public InvItem this[byte key]
        {
            get
            {
                lock (mylock) return m_Items[key - 1];
            }
        }

        #region Events/Funcs/Actions
        public Item onWearEquip(byte loc)
        {
            if ((loc > 0) && (loc < 51))
            {
                if (this[loc].ItemID > 0)
                {
                    InvItem i = new InvItem();
                    i.CopyFrom(this[loc]);
                    this[loc].Clear();
                    return i;
                }
                return null;
            }
            return null;
        }

        public bool onUnEquip(Item src, byte loc, bool senddata)
        {
            if (src == null) return false;
            return (AddItem(src, loc, senddata) > 0);
        }

        public void onItemDropped_fromMap(byte loc, byte ammt)
        {
            RemoveItem(loc, ammt);
        }

        public bool onItemPickedUp_fromMap(Item item)
        {
            return (AddItem(item) > 0);
        }

        public ushort GetItemIdAtSlot(byte loc)
        {
            if (loc > 0 && loc <= 50)
            {
                lock (mylock) return this[loc].ItemID;
            }
            return 0;
        }

        public void RemoveItemAtSlot(byte loc, byte ammt = 1)
        {
            if (loc > 0 && loc <= 50)
                RemoveItem(loc, ammt);
        }
        #endregion

        public bool ContainsItem(ushort ItemID)
        {
            lock (mylock)
            {
                for (byte a = 1; a < 51; a++)
                {
                    if (this[a].ItemID == ItemID)
                        return true;
                }
                return false;
            }
        }

        public bool ContainsItem(ushort ItemID, out byte slot)
        {
            lock (mylock)
            {
                for (byte a = 1; a < 51; a++)
                {
                    if (this[a].ItemID == ItemID)
                    {
                        slot = a;
                        return true;
                    }
                }
                slot = 0;
                return false;
            }
        }

        public int GetItemCount(ushort ItemID)
        {
            lock (mylock)
            {
                int total = 0;
                for (byte a = 1; a < 51; a++)
                {
                    if (this[a].ItemID == ItemID)
                        total += Math.Max(1, (int)this[a].Ammt);
                }
                return total;
            }
        }

        public bool RemoveItemById(ushort itemId, byte ammt = 1)
        {
            if (ContainsItem(itemId, out byte slot))
            {
                RemoveItem(slot, ammt);
                return true;
            }
            return false;
        }

        /// <summary>
        /// Builds the Rhode Island client slot-state packet confirmed elsewhere in the
        /// protocol implementation (AC 23:8): slot, item id, quantity, 28 reserved bytes.
        /// AC 23:6 is only an acquisition/banner packet and does not identify a bag slot.
        /// </summary>
        private SendPacket BuildSlotStatePacket(byte slot)
        {
            if (slot < 1 || slot > 50) return null;
            var current = this[slot];
            if (current == null || current.ItemID == 0) return null;

            SendPacket pkt = new SendPacket();
            pkt.Pack8(23);
            pkt.Pack8(8);
            pkt.Pack8(slot);
            pkt.Pack16(current.ItemID);
            pkt.Pack8(Math.Max((byte)1, current.Ammt));
            pkt.PackArray(new byte[28]);
            return pkt;
        }

        private void SendAcquisitionPacket(ushort itemId, int amount)
        {
            if (owner == null || itemId == 0 || amount <= 0) return;

            SendPacket pkt = new SendPacket();
            pkt.Pack8(23);
            pkt.Pack8(6);
            pkt.Pack16(itemId);
            pkt.Pack8((byte)Math.Min(255, amount));
            pkt.PackArray(new byte[28]);
            owner.Send(pkt);
        }

        /// <summary>
        /// Pushes the authoritative state of a single occupied inventory slot.
        /// </summary>
        public void SendSlotState(byte slot)
        {
            lock (mylock)
            {
                if (owner == null) return;
                var pkt = BuildSlotStatePacket(slot);
                if (pkt != null)
                    owner.Send(pkt);
            }
        }

        /// <summary>
        /// Sends both the legacy AC23:5 snapshot and explicit AC23:8 slot packets.
        /// The Rhode Island client used by this server has been observed to require the
        /// explicit slot packets even when the snapshot is present.
        /// </summary>
        public void SendFullSync()
        {
            lock (mylock)
            {
                if (owner == null) return;

                owner.Send(new SendPacket(GetAC23_5()));
                for (byte slot = 1; slot <= 50; slot++)
                {
                    var pkt = BuildSlotStatePacket(slot);
                    if (pkt != null)
                        owner.Send(pkt);
                }
            }
        }

        private PhxItemInfo ResolveItemInfo(ushort itemId)
        {
            if (itemId == 0 || ItemDat == null) return null;
            try
            {
                return ItemDat.GetItemByID(itemId);
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[Inventory] Failed to resolve Item.dat entry #{itemId}: {ex.Message}");
                return null;
            }
        }

        /// <summary>
        /// Returns how many units of the supplied item can currently fit without mutating
        /// inventory. Used by Item Mall and reward systems to avoid partial deliveries.
        /// </summary>
        public int GetAddCapacity(ushort itemId)
        {
            var info = ResolveItemInfo(itemId);
            if (info == null) return 0;

            InvItem item = new InvItem();
            item.CopyFrom(info);
            item.Ammt = 1;
            return GetAddCapacity(item);
        }

        public int GetAddCapacity(Item item)
        {
            lock (mylock)
            {
                if (item == null || item.ItemID == 0) return 0;

                int capacity = 0;
                for (byte slot = 1; slot <= 50; slot++)
                {
                    var cur = this[slot];
                    if (cur == null) continue;

                    if (cur.ItemID == 0)
                    {
                        capacity += item.Stackable ? 50 : 1;
                    }
                    else if (item.Stackable && cur.ItemID == item.ItemID)
                    {
                        capacity += Math.Max(0, cur.SpaceLeft);
                    }
                }
                return capacity;
            }
        }

        /// <summary>
        /// Applies durability damage / wear to the active vehicle in inventory on movement.
        /// </summary>
        public void ApplyVehicleWear(ushort vehicleItemId, byte wearAmount = 1)
        {
            lock (mylock)
            {
                if (ContainsItem(vehicleItemId, out byte slot))
                {
                    var item = this[slot];
                    if (item != null && item.ItemID > 0)
                    {
                        int newDmg = item.Damage + wearAmount;
                        if (newDmg >= 100)
                        {
                            item.Damage = 100;
                            RemoveItem(slot, 1);

                            SendPacket wreck = new SendPacket();
                            wreck.Pack8(15);
                            wreck.Pack8(15);
                            wreck.Pack32(owner.CharID);
                            wreck.Pack16(vehicleItemId);
                            owner.Send(wreck);
                            owner.CurMap?.Broadcast(wreck);

                            owner.ActiveVehicleID = 0;
                            owner.RideVehicle("");
                            owner.SaveCharacterData();
                            owner.SendSystemMessage("Your raft broke into pieces from wear and tear!");
                        }
                        else
                        {
                            item.Damage = (byte)newDmg;
                            SendSlotState(slot);
                        }
                    }
                }
            }
        }

        public void RemoveAll(bool force)
        {
            lock (mylock)
            {
                for (byte a = 1; a < 51; a++)
                {
                    if (!force)
                    {
                        if (this[a].ItemID > 0)
                            RemoveItem(a, this[a].Ammt);
                    }
                    else
                    {
                        this[a].Clear();
                    }
                }
            }
        }

        /// <summary>
        /// Removes units from a slot and keeps server/client quantity in agreement.
        /// The returned item contains only the quantity actually removed (important for
        /// partial stack moves; the old implementation returned the entire source stack).
        /// </summary>
        public InvItem RemoveItem(byte at, byte ammt, bool senddata = true)
        {
            lock (mylock)
            {
                if (at < 1 || at > 50 || ammt == 0) return null;
                var source = this[at];
                if (source == null || source.ItemID == 0) return null;

                try
                {
                    byte removedAmount = (byte)Math.Min(source.Ammt, ammt);
                    InvItem remItem = new InvItem();
                    remItem.CopyFrom(source);
                    remItem.Ammt = removedAmount;

                    if (source.Ammt <= removedAmount)
                        source.Clear();
                    else
                        source.Ammt -= removedAmount;

                    if (senddata && owner != null)
                    {
                        owner.Send(Tools.FromFormat("bbbb", 23, 9, at, removedAmount));
                        if (source.ItemID > 0)
                            SendSlotState(at);
                    }
                    return remItem;
                }
                catch (Exception e)
                {
                    DebugSystem.Write(new ExceptionData(e));
                    return null;
                }
            }
        }

        public bool RemoveItem(ushort itemId, byte count = 1)
        {
            lock (mylock)
            {
                int needed = count;
                for (byte a = 1; a < 51 && needed > 0; a++)
                {
                    if (this[a].ItemID == itemId)
                    {
                        byte toTake = (byte)Math.Min(this[a].Ammt, needed);
                        RemoveItem(a, toTake);
                        needed -= toTake;
                    }
                }
                return needed == 0;
            }
        }

        public void AddItem(ushort ID, byte amt)
        {
            AddItemWithResult(ID, amt, true);
        }

        public void AddItem(ushort ID, byte amt, bool sendData)
        {
            AddItemWithResult(ID, amt, sendData);
        }

        /// <summary>
        /// Adds an Item.dat item and returns the number of units actually inserted.
        /// Unknown Item.dat IDs are rejected instead of creating ghost inventory records
        /// that the client cannot render.
        /// </summary>
        public int AddItemWithResult(ushort ID, byte amt, bool sendData = true)
        {
            if (ID == 0 || amt == 0) return 0;

            PhxItemInfo baseItem = ResolveItemInfo(ID);
            if (baseItem == null)
            {
                DebugSystem.Write($"[Inventory.AddItem] Rejected unknown Item.dat ID #{ID} for {owner?.CharName ?? "Unknown"}.");
                return 0;
            }

            InvItem i = new InvItem();
            i.CopyFrom(baseItem);
            i.Ammt = amt;
            return AddItem(i, 0, sendData);
        }

        /// <summary>
        /// Adds an item to the inventory. AC23:6 is retained as the acquisition/banner
        /// notification, while AC23:8 sends the actual destination slot state.
        /// </summary>
        public int AddItem(Item item, byte at = 0, bool sendData = true)
        {
            lock (mylock)
            {
                if (item == null || item.ItemID == 0 || item.Ammt == 0) return 0;

                int needed = item.Ammt;
                int addedTotal = 0;
                List<byte> touchedSlots = new List<byte>();

                if (at >= 1 && at <= 50)
                {
                    var target = this[at];
                    if (target.ItemID == 0)
                    {
                        target.CopyFrom(item);
                        target.Parent = 0;
                        int toPut = item.Stackable ? Math.Min(needed, 50) : 1;
                        target.Ammt = (byte)toPut;
                        addedTotal = toPut;
                        touchedSlots.Add(at);
                    }
                    else if (target.ItemID == item.ItemID && item.Stackable && target.SpaceLeft > 0)
                    {
                        int toStack = Math.Min(needed, target.SpaceLeft);
                        target.Ammt += (byte)toStack;
                        addedTotal = toStack;
                        touchedSlots.Add(at);
                    }

                    if (addedTotal > 0 && sendData && owner != null)
                    {
                        SendAcquisitionPacket(item.ItemID, addedTotal);
                        SendSlotState(at);
                        DebugSystem.Write($"[Inventory.AddItem] Placed item #{item.ItemID} x{addedTotal} into slot {at} for {owner.CharName}");
                    }
                    return addedTotal;
                }

                if (item.Stackable)
                {
                    for (byte s = 1; s <= 50 && needed > 0; s++)
                    {
                        var cur = this[s];
                        if (cur != null && cur.ItemID == item.ItemID && cur.SpaceLeft > 0)
                        {
                            int toStack = Math.Min(needed, cur.SpaceLeft);
                            cur.Ammt += (byte)toStack;
                            needed -= toStack;
                            addedTotal += toStack;
                            touchedSlots.Add(s);
                            DebugSystem.Write($"[Inventory.AddItem] Stacked item #{item.ItemID} x{toStack} onto slot {s} for {owner?.CharName ?? "Unknown"} (New Ammt: {cur.Ammt})");
                        }
                    }
                }

                for (byte s = 1; s <= 50 && needed > 0; s++)
                {
                    var cur = this[s];
                    if (cur != null && cur.ItemID == 0)
                    {
                        cur.CopyFrom(item);
                        cur.Parent = 0;
                        int toPlace = item.Stackable ? Math.Min(needed, 50) : 1;
                        cur.Ammt = (byte)toPlace;
                        needed -= toPlace;
                        addedTotal += toPlace;
                        touchedSlots.Add(s);
                        DebugSystem.Write($"[Inventory.AddItem] Added new item #{item.ItemID} x{toPlace} into slot {s} for {owner?.CharName ?? "Unknown"}");
                    }
                }

                if (addedTotal > 0 && sendData && owner != null)
                {
                    SendAcquisitionPacket(item.ItemID, addedTotal);
                    foreach (byte slot in touchedSlots.Distinct())
                        SendSlotState(slot);
                }

                if (needed > 0)
                    DebugSystem.Write($"[Inventory.AddItem] Inventory capacity shortfall for #{item.ItemID}: requested {item.Ammt}, added {addedTotal}, remaining {needed} ({owner?.CharName ?? "Unknown"}).");

                return addedTotal;
            }
        }

        /// <summary>
        /// Moves inventory data without losing or duplicating partial stacks.
        /// </summary>
        public void MoveItem(byte from, byte to, byte ammt)
        {
            lock (mylock)
            {
                if (from < 1 || from > 50 || to < 1 || to > 50 || ammt == 0 || from == to) return;

                var source = this[from];
                var destination = this[to];
                if (source == null || source.ItemID == 0 || destination == null) return;

                byte moveAmount = (byte)Math.Min(source.Ammt, ammt);
                if (destination.ItemID != 0)
                {
                    if (destination.ItemID != source.ItemID || !source.Stackable || destination.SpaceLeft < moveAmount)
                        return;
                }

                var moving = RemoveItem(from, moveAmount, false);
                if (moving == null) return;

                int placed = AddItem(moving, to, false);
                if (placed != moveAmount)
                {
                    AddItem(moving, from, false);
                    DebugSystem.Write($"[Inventory.MoveItem] Rolled back failed move {from}->{to} for {owner?.CharName ?? "Unknown"}.");
                    SendFullSync();
                    return;
                }

                if (owner != null)
                {
                    SendPacket tmp = new SendPacket();
                    tmp.Pack8(23);
                    tmp.Pack8(10);
                    tmp.Pack8(from);
                    tmp.Pack8(moveAmount);
                    tmp.Pack8(to);
                    owner.Send(tmp);

                    if (this[from].ItemID > 0)
                        SendSlotState(from);
                    SendSlotState(to);
                }
            }
        }

        public void ProcessSocket(RecievePacket p)
        {
            p.SetPtr();

            var a = p.Unpack8();
            var b = p.Unpack8();

            if (a != 23) return;

            switch (b)
            {
                case 10:
                {
                    byte src = p.Unpack8();
                    byte ammt = p.Unpack8();
                    byte dst = p.Unpack8();
                    if (src > 0 && src < 51 && dst > 0 && dst < 51 && ammt > 0 && ammt < 51)
                        MoveItem(src, dst, ammt);
                    break;
                }
                case 15:
                {
                    byte pos = p.Unpack8();
                    if (pos > 0 && pos < 51 && this[pos].ItemID > 0)
                    {
                        switch (this[pos].Type)
                        {
                            case eItemType.Tent:
                                owner.Tent.Open();
                                break;
                        }
                    }
                    break;
                }
                case 3:
                {
                    byte pos = p.Unpack8();
                    byte qnt = p.Unpack8();
                    byte ukn = p.Unpack8();
                    if (pos > 0 && pos < 51 && this[pos].ItemID > 0)
                    {
                        owner.Send(Tools.FromFormat("bbWb", 23, 26, this[pos].ItemID, qnt));
                        RemoveItem(pos, qnt);
                    }
                    break;
                }
            }
        }

        bool CanPlace(byte cell, Item item)
        {
            lock (mylock)
            {
                if (cell < 1 || cell > 50 || item == null) return false;
                var cur = this[cell];
                if (cur == null) return false;
                if (cur.ItemID == 0) return true;
                if (cur.ItemID == item.ItemID && item.Stackable && cur.SpaceLeft > 0) return true;
                return false;
            }
        }

        public int FilledCount
        {
            get { lock (mylock) { return m_Items.Count(c => c != null && c.ItemID > 0); } }
        }

        public int unFilledCount
        {
            get { lock (mylock) { return 50 - FilledCount; } }
        }

        public byte[] GetAC23_5()
        {
            lock (mylock)
            {
                SendPacket tmp = new SendPacket();
                tmp.Pack8(23);
                tmp.Pack8(5);
                if (FilledCount > 0)
                {
                    for (byte a = 1; a < 51; a++)
                    {
                        if (this[a].ItemID != 0)
                        {
                            tmp.Pack8(a);
                            tmp.Pack16(this[a].ItemID);
                            tmp.Pack8(this[a].Ammt);
                            tmp.Pack8(this[a].Damage);
                            tmp.PackArray(new byte[24]);
                        }
                    }
                }
                return tmp.Buffer;
            }
        }

        public byte[] GetAC30_5(byte actionCode = 30, byte subCode = 5)
        {
            lock (mylock)
            {
                SendPacket tmp = new SendPacket();
                tmp.Pack8(actionCode);
                tmp.Pack8(subCode);
                if (FilledCount > 0)
                {
                    for (byte a = 1; a < 51; a++)
                    {
                        if (this[a].ItemID != 0)
                        {
                            tmp.Pack8(a);
                            tmp.Pack16(this[a].ItemID);
                            tmp.Pack8(this[a].Ammt);
                            tmp.Pack8(this[a].Damage);
                            tmp.PackArray(new byte[24]);
                        }
                    }
                }
                return tmp.Buffer;
            }
        }

        public Dictionary<byte, uint[]> InventoryDBData
        {
            get
            {
                lock (mylock)
                {
                    Dictionary<byte, uint[]> tmp = new Dictionary<byte, uint[]>();
                    for (byte a = 1; a < 51; a++)
                        tmp.Add(a, new uint[] { this[a].ItemID, this[a].Damage, this[a].Ammt, a, 0, 0, 0, 0 });
                    return tmp;
                }
            }
        }

        public void onItemUsed(byte slot, byte tgrt, byte ammt)
        {
            // Legacy hook retained for compatibility. Active item use is handled in AC23.
        }

        public void onItemCanceled(byte slot)
        {
            // Legacy hook retained for compatibility.
        }

        int MatrixtoNumber(int a, int b) { return ((a * 5) + (b - 5)); }

        byte[] NumbertoMatrix(int a)
        {
            var s = 0;
            if (a == 5 || a == 10 || a == 15 || a == 20 || a == 25 || a == 30 || a == 35 || a == 40 || a == 45 || a == 50)
                s = (a / 5);
            else
                s = 1 + (a / 5);

            var t = 0;
            if (a == 5 || a == 10 || a == 15 || a == 20 || a == 25 || a == 30 || a == 35 || a == 40 || a == 45 || a == 50)
                t = 5;
            else if (a > 5)
                t = 5 - (((1 + (a / 5)) * 5) - a);
            else
                t = a;

            byte[] matrixloc = new byte[2];
            matrixloc[0] = (byte)s;
            matrixloc[1] = (byte)t;
            return matrixloc;
        }
    }

    public class TentInventoryManager : Inventory
    {
        public TentInventoryManager(Player src, global::DataFiles.PhxItemDat ItemDat)
            : base(src, ItemDat)
        {
        }
    }
}
