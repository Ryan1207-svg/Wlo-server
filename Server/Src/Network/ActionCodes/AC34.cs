using System;
using Game;
using Game.PlayerRelated;
using Network;

namespace Network.ActionCodes
{
    /// <summary>
    /// AC 34: In-Game Shopping Cart Checkout & Points Synchronization Protocol.
    /// - AC 34 Sub 1 [0]: balance/catalog request
    /// - AC 34 Sub 1 [mode >= 1]: cart checkout by advertised catalog row
    /// - AC 34 Sub 2: direct purchase [itemId:uint16, quantity:uint8]
    /// </summary>
    public class AC34 : AC
    {
        public override int ID { get { return 34; } }

        public override void ProcessPkt(Player r, RecievePacket p)
        {
            byte subcode = p.Unpack8();
            switch (subcode)
            {
                case 1:
                    Recv1(r, p);
                    break;
                case 2:
                    Recv2(r, p);
                    break;
                default:
                    DebugSystem.Write($"[AC34] Subcode {subcode} not handled");
                    break;
            }
        }

        private static void SendCheckoutSync(Player p)
        {
            uint remPoints = (uint)ItemMallManager.GetUserPoints(p);

            SendPacket balance = new SendPacket();
            balance.Pack8(34);
            balance.Pack8(1);
            balance.Pack32(remPoints);
            p.Send(balance);

            ItemMallManager.SendPointBalance(p);

            // Cart-clear/confirmation packet observed in Rhode Island captures.
            SendPacket cartAck = new SendPacket();
            cartAck.Pack8(35);
            cartAck.Pack8(4);
            for (int i = 0; i < 16; i++) cartAck.Pack8(0);
            p.Send(cartAck);

            ItemMallManager.SendCatalog(p, isBonus: false);
        }

        void Recv1(Player p, RecievePacket r)
        {
            try
            {
                byte mode = 0;
                try { mode = r.Unpack8(); } catch { mode = 0; }

                uint points = (uint)ItemMallManager.GetUserPoints(p);
                if (mode == 0)
                {
                    SendPacket resp = new SendPacket();
                    resp.Pack8(34);
                    resp.Pack8(1);
                    resp.Pack32(points);
                    p.Send(resp);

                    ItemMallManager.SendPointBalance(p);
                    ItemMallManager.SendCatalog(p, isBonus: false);
                    DebugSystem.Write($"[AC34.Recv1] Synced IM points ({points} IM) and sent catalog for {p.CharName}");
                    return;
                }

                // mode is a 1-based advertised catalog row. Preserve the exact row rather
                // than reducing it to ItemID: the same WLO item can have single and bundle
                // listings (Potential Pill is one example).
                int catIndex = mode - 1;
                MallItemEntry itemToBuy = ItemMallManager.GetCatalogEntry(catIndex, isBonus: false);

                if (itemToBuy == null)
                {
                    DebugSystem.Write($"[AC34.Recv1] Rejected invalid Cart Slot #{mode} from {p.CharName}");
                    p.SendSystemMessage("The selected Item Mall row is invalid. Please reopen the mall and try again.");
                    SendCheckoutSync(p);
                    return;
                }

                bool success = ItemMallManager.PurchaseEntry(p, itemToBuy, 1, isBonus: false);
                SendCheckoutSync(p);

                DebugSystem.Write(
                    $"[AC34.Recv1] Cart Checkout Slot #{mode} -> {itemToBuy.ItemName} " +
                    $"(#{itemToBuy.ItemID}, bundle x{itemToBuy.Count}) by {p.CharName}: {(success ? "Success" : "Failed")}");
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[AC34.Recv1] Error: {ex.Message}\n{ex.StackTrace}");
            }
        }

        void Recv2(Player p, RecievePacket r)
        {
            try
            {
                int rem = r.Buffer.Length - r.GetPtr();
                if (rem < 2)
                {
                    DebugSystem.Write($"[AC34.Recv2] Malformed AC 34 Sub 2 packet from {p.CharName}");
                    return;
                }

                ushort itemId = r.Unpack16();
                byte quantity = 1;
                if (r.Buffer.Length - r.GetPtr() >= 1)
                {
                    try { quantity = r.Unpack8(); } catch { quantity = 1; }
                }
                if (quantity == 0) quantity = 1;

                DebugSystem.Write($"[AC34.Recv2] Direct Mall Purchase #{itemId} x{quantity} by {p.CharName}");

                // For the direct-purchase variant the third byte has historically been
                // interpreted as requested package quantity. Keep that behavior until a
                // Rhode Island capture proves it is the advertised bundle count.
                bool success = ItemMallManager.PurchaseItem(p, itemId, quantity, isBonus: false);
                SendCheckoutSync(p);

                DebugSystem.Write($"[AC34.Recv2] Direct purchase #{itemId} x{quantity} by {p.CharName}: {(success ? "Success" : "Failed")}");
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[AC34.Recv2] Error: {ex.Message}\n{ex.StackTrace}");
            }
        }
    }
}
