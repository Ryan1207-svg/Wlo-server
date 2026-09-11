using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using Game;
using Game.Code;
using MySql.Data.MySqlClient;
using RCLibrary.Core;

namespace DataBase
{
    public enum GMStatus
    {
        None,
    }

    public sealed class UserDataBase : RCLibrary.Core.DataBase
    {
        readonly object mylock = new object();

        // Used to provide flexibility to alter column names and match them with the correct value.
        public string TableName = "users";
        public string Username_Ref = "username";
        public string Password_Ref = "password";
        public string DataBaseID_Ref = "userID";
        public string CharacterID1_Ref = "character1ID";
        public string CharacterID2_Ref = "character2ID";
        public string IM_Ref = "IM";
        public string Char_Delete_Code_Ref = "char_delete_code";
        public VerifyPassType PassVerification;

        readonly List<User> GOnlineUsers = new List<User>();

        public UserDataBase()
        {
        }

        private bool TableExists()
        {
            try
            {
                return GetDataTable("SELECT * FROM " + TableName + " LIMIT 1") != null;
            }
            catch
            {
                return false;
            }
        }

        private bool ColumnExists(string column)
        {
            if (string.IsNullOrWhiteSpace(column)) return false;
            try
            {
                return GetDataTable("SELECT " + column + " FROM " + TableName + " WHERE 1 = 0") != null;
            }
            catch
            {
                return false;
            }
        }

        private void EnsureColumn(string column, string sqliteDefinition, string mysqlDefinition)
        {
            if (string.IsNullOrWhiteSpace(column) || ColumnExists(column)) return;

            try
            {
                string definition = ServType == RCLibrary.Core.DataBaseTypes.MySQl
                    ? mysqlDefinition
                    : sqliteDefinition;
                ExecuteNonQuery("ALTER TABLE " + TableName + " ADD COLUMN " + column + " " + definition);
                DebugSystem.Write($"[UserDataBase] Added missing users.{column} column.");
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[UserDataBase] Could not add users.{column}: {ex.Message}");
            }
        }

        /// <summary>
        /// Verifies the account table without deleting existing accounts. Older versions of this
        /// method dropped the whole users table when a column was missing; that is unsafe for a
        /// live server and also left web-created accounts without fields expected by game login.
        /// </summary>
        public void VerifySetup()
        {
            DebugSystem.Write("Checking for users table");

            if (!TableExists())
            {
                DebugSystem.Write("Setting up users table");
                try
                {
                    if (ServType == RCLibrary.Core.DataBaseTypes.MySQl)
                    {
                        ExecuteNonQuery(
                            "CREATE TABLE IF NOT EXISTS " + TableName + " (" +
                            DataBaseID_Ref + " INT(11) NOT NULL AUTO_INCREMENT PRIMARY KEY," +
                            Username_Ref + " VARCHAR(64) NOT NULL," +
                            Password_Ref + " TEXT NOT NULL," +
                            "email VARCHAR(255) NOT NULL DEFAULT ''," +
                            CharacterID1_Ref + " INT(11) NOT NULL DEFAULT 0," +
                            CharacterID2_Ref + " INT(11) NOT NULL DEFAULT 0," +
                            IM_Ref + " INT(11) NOT NULL DEFAULT 0," +
                            "im_bonus INT(11) NOT NULL DEFAULT 0," +
                            Char_Delete_Code_Ref + " VARCHAR(255) NOT NULL DEFAULT ''" +
                            ") ENGINE=InnoDB DEFAULT CHARSET=utf8;");
                    }
                    else
                    {
                        ExecuteNonQuery(
                            "CREATE TABLE IF NOT EXISTS " + TableName + " (" +
                            DataBaseID_Ref + " INTEGER PRIMARY KEY AUTOINCREMENT," +
                            Username_Ref + " TEXT NOT NULL," +
                            Password_Ref + " TEXT NOT NULL," +
                            "email TEXT NOT NULL DEFAULT ''," +
                            CharacterID1_Ref + " INTEGER NOT NULL DEFAULT 0," +
                            CharacterID2_Ref + " INTEGER NOT NULL DEFAULT 0," +
                            IM_Ref + " INTEGER NOT NULL DEFAULT 0," +
                            "im_bonus INTEGER NOT NULL DEFAULT 0," +
                            Char_Delete_Code_Ref + " TEXT NOT NULL DEFAULT ''" +
                            ");");
                    }
                }
                catch (Exception ex)
                {
                    DebugSystem.Write($"[UserDataBase] Failed to create users table: {ex.Message}");
                    return;
                }
            }

            // Never drop an existing users table. Add the game-facing fields non-destructively.
            if (!ColumnExists(DataBaseID_Ref) || !ColumnExists(Username_Ref) || !ColumnExists(Password_Ref))
            {
                DebugSystem.Write("[UserDataBase] ERROR: users table is missing a core userID/username/password column. Existing data was left untouched.");
                return;
            }

            EnsureColumn("email", "TEXT NOT NULL DEFAULT ''", "VARCHAR(255) NOT NULL DEFAULT ''");
            EnsureColumn(CharacterID1_Ref, "INTEGER NOT NULL DEFAULT 0", "INT(11) NOT NULL DEFAULT 0");
            EnsureColumn(CharacterID2_Ref, "INTEGER NOT NULL DEFAULT 0", "INT(11) NOT NULL DEFAULT 0");
            EnsureColumn(IM_Ref, "INTEGER NOT NULL DEFAULT 0", "INT(11) NOT NULL DEFAULT 0");
            EnsureColumn("im_bonus", "INTEGER NOT NULL DEFAULT 0", "INT(11) NOT NULL DEFAULT 0");
            EnsureColumn(Char_Delete_Code_Ref, "TEXT NOT NULL DEFAULT ''", "VARCHAR(255) NOT NULL DEFAULT ''");

            // SQLite is the normal WLO server backend. Protect account names at the DB layer as
            // well as in RegisterUser; if an old DB already contains duplicates this simply logs
            // the problem instead of damaging either row.
            if (ServType == RCLibrary.Core.DataBaseTypes.Sqlite)
            {
                try
                {
                    ExecuteNonQuery("CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username ON " + TableName + " (" + Username_Ref + ")");
                }
                catch (Exception ex)
                {
                    DebugSystem.Write($"[UserDataBase] Could not create username unique index: {ex.Message}");
                }
            }

            DebugSystem.Write("Found and verified users table");
        }

        public int Count()
        {
            lock (mylock) return GOnlineUsers.Count;
        }

        public bool isLoggedin(string user)
        {
            lock (mylock)
            {
                bool resp = GOnlineUsers.Any(c => c != null && c.UserName == user);
                DebugSystem.Write(DebugItemType.Info_Heavy, "Checking if User '{0}' is Online... [Resp]: {1}", DebugItemType.Info_Heavy, user, resp);
                return resp;
            }
        }

        public override bool VerifyPassword(string check, string with)
        {
            return base.VerifyPassword(check, with);
        }

        public override bool VerifySaltedPassword(string password, string salt, string with)
        {
            return (hashMD5(hashMD5(salt) + hashMD5(password)) == with);
        }

        public bool Update_Player_ID(uint user, UInt32 id, byte slot)
        {
            if (user == 0 || (slot != 1 && slot != 2)) return false;
            string column = slot == 1 ? CharacterID1_Ref : CharacterID2_Ref;
            if (!ColumnExists(column)) return false;

            try
            {
                ExecuteNonQuery(
                    "UPDATE " + TableName + " SET " + column + " = @charId WHERE " + DataBaseID_Ref + " = @uid",
                    new DbParam("@charId", id),
                    new DbParam("@uid", user));
                return true;
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[UserDataBase] Error updating {column}: {ex.Message}");
                return false;
            }
        }

        public bool GetUserData(string user, string pass, out uint userID, out string[] userData)
        {
            userID = 0;
            userData = null;

            if (string.IsNullOrWhiteSpace(user) || pass == null) return false;

            try
            {
                var src = GetDataTable(
                    "SELECT * FROM " + TableName + " WHERE " + Username_Ref + " = @id",
                    new DbParam("@id", user));

                if (src == null || src.Rows.Count == 0)
                {
                    DebugSystem.Write($"[UserDataBase.GetUserData] No user found with username '{user}'");
                    return false;
                }

                DataRow row = src.Rows[0];
                bool validPassword = false;

                switch (PassVerification)
                {
                    case VerifyPassType.None:
                        validPassword = VerifyPassword(pass, row[Password_Ref].ToString());
                        break;

                    case VerifyPassType.IPBoard_3x:
                        if (src.Columns.Contains("members_pass_salt"))
                            validPassword = VerifySaltedPassword(pass, row["members_pass_salt"].ToString(), row[Password_Ref].ToString());
                        break;
                }

                if (!validPassword)
                {
                    DebugSystem.Write($"[UserDataBase.GetUserData] Password verification failed for '{user}'.");
                    return false;
                }

                if (!uint.TryParse(row[DataBaseID_Ref].ToString(), out userID) || userID == 0)
                {
                    DebugSystem.Write($"[UserDataBase.GetUserData] Invalid userID for '{user}'.");
                    userID = 0;
                    return false;
                }

                string cipher = string.Empty;
                if (src.Columns.Contains(Char_Delete_Code_Ref) && row[Char_Delete_Code_Ref] != DBNull.Value)
                    cipher = row[Char_Delete_Code_Ref].ToString();

                string imValue = "0";
                if (src.Columns.Contains(IM_Ref) && row[IM_Ref] != DBNull.Value && !string.IsNullOrWhiteSpace(row[IM_Ref].ToString()))
                    imValue = row[IM_Ref].ToString();

                userData = new[] { row[Username_Ref].ToString(), cipher, imValue };
                DebugSystem.Write($"[UserDataBase.GetUserData] Authenticated '{user}' as userID={userID}.");
                return true;
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[UserDataBase.GetUserData] Error authenticating '{user}': {ex.Message}\n{ex.StackTrace}");
                userID = 0;
                userData = null;
                return false;
            }
        }

        public int GetIMPoints(uint user)
        {
            if (user == 0 || !ColumnExists(IM_Ref)) return 0;
            try
            {
                var src = GetDataTable(
                    "SELECT " + IM_Ref + " FROM " + TableName + " WHERE " + DataBaseID_Ref + " = @uid",
                    new DbParam("@uid", user));
                if (src != null && src.Rows.Count > 0 && src.Rows[0][IM_Ref] != DBNull.Value)
                {
                    int points;
                    if (int.TryParse(src.Rows[0][IM_Ref].ToString(), out points)) return points;
                }
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[UserDataBase] Error reading IM points: {ex.Message}");
            }
            return 0;
        }

        public bool SetIMPoints(uint userId, int points)
        {
            if (userId == 0) return false;
            EnsureColumn(IM_Ref, "INTEGER NOT NULL DEFAULT 0", "INT(11) NOT NULL DEFAULT 0");
            try
            {
                string query = "UPDATE " + TableName + " SET " + IM_Ref + " = @im WHERE " + DataBaseID_Ref + " = @uid";
                ExecuteNonQuery(query, new DbParam("@im", Math.Max(0, points)), new DbParam("@uid", userId));
                return true;
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[UserDataBase] Error updating IM points: {ex.Message}");
                return false;
            }
        }

        public bool SetIMBonusPoints(uint userId, int bonusPoints)
        {
            if (userId == 0) return false;
            EnsureColumn("im_bonus", "INTEGER NOT NULL DEFAULT 0", "INT(11) NOT NULL DEFAULT 0");
            try
            {
                string query = "UPDATE " + TableName + " SET im_bonus = @bonus WHERE " + DataBaseID_Ref + " = @uid";
                ExecuteNonQuery(query, new DbParam("@bonus", Math.Max(0, bonusPoints)), new DbParam("@uid", userId));
                return true;
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[UserDataBase] Error updating IM bonus points: {ex.Message}");
                return false;
            }
        }

        public int GetIMBonusPoints(uint user)
        {
            if (user == 0 || !ColumnExists("im_bonus")) return 0;
            try
            {
                var dt = GetDataTable(
                    "SELECT im_bonus FROM " + TableName + " WHERE " + DataBaseID_Ref + " = @uid",
                    new DbParam("@uid", user));
                if (dt != null && dt.Rows.Count > 0 && dt.Rows[0]["im_bonus"] != DBNull.Value)
                    return Convert.ToInt32(dt.Rows[0]["im_bonus"]);
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[UserDataBase] Error reading IM bonus points: {ex.Message}");
            }
            return 0;
        }

        public bool UpdateUser(uint user, string delete = null, object im = null, object char1 = null, object char2 = null)
        {
            if (user == 0) return false;

            try
            {
                if (delete != null && ColumnExists(Char_Delete_Code_Ref))
                    ExecuteNonQuery("UPDATE " + TableName + " SET " + Char_Delete_Code_Ref + " = @value WHERE " + DataBaseID_Ref + " = @uid", new DbParam("@value", delete), new DbParam("@uid", user));
                if (im != null && ColumnExists(IM_Ref))
                    ExecuteNonQuery("UPDATE " + TableName + " SET " + IM_Ref + " = @value WHERE " + DataBaseID_Ref + " = @uid", new DbParam("@value", im), new DbParam("@uid", user));
                if (char1 != null && ColumnExists(CharacterID1_Ref))
                    ExecuteNonQuery("UPDATE " + TableName + " SET " + CharacterID1_Ref + " = @value WHERE " + DataBaseID_Ref + " = @uid", new DbParam("@value", char1), new DbParam("@uid", user));
                if (char2 != null && ColumnExists(CharacterID2_Ref))
                    ExecuteNonQuery("UPDATE " + TableName + " SET " + CharacterID2_Ref + " = @value WHERE " + DataBaseID_Ref + " = @uid", new DbParam("@value", char2), new DbParam("@uid", user));
                return true;
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[UserDataBase] Error updating user {user}: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Registers a game-ready account. A web signup is only reported as successful after
        /// the same GetUserData authentication path used by the server can read it back.
        /// </summary>
        public bool RegisterUser(string username, string password, string email, out string errorMessage)
        {
            errorMessage = string.Empty;
            username = (username ?? string.Empty).Trim();
            email = (email ?? string.Empty).Trim();

            if (username.Length < 3 || username.Length > 20 || !username.All(ch => char.IsLetterOrDigit(ch) || ch == '_'))
            {
                errorMessage = "Invalid username";
                return false;
            }
            if (string.IsNullOrEmpty(password) || password.Length < 4 || password.Length > 64)
            {
                errorMessage = "Invalid password";
                return false;
            }
            if (string.IsNullOrWhiteSpace(email) || email.Length > 255)
            {
                errorMessage = "Invalid email";
                return false;
            }

            lock (mylock)
            {
                try
                {
                    VerifySetup();

                    var existing = GetDataTable(
                        "SELECT " + DataBaseID_Ref + " FROM " + TableName + " WHERE " + Username_Ref + " = @username",
                        new DbParam("@username", username));

                    if (existing != null && existing.Rows.Count > 0)
                    {
                        errorMessage = "Username already exists";
                        return false;
                    }

                    var columns = new List<string> { Username_Ref, Password_Ref };
                    var values = new List<string> { "@username", "@password" };
                    var parameters = new List<DbParam>
                    {
                        new DbParam("@username", username),
                        new DbParam("@password", password)
                    };

                    if (ColumnExists("email"))
                    {
                        columns.Add("email");
                        values.Add("@email");
                        parameters.Add(new DbParam("@email", email));
                    }
                    if (ColumnExists(CharacterID1_Ref))
                    {
                        columns.Add(CharacterID1_Ref);
                        values.Add("@char1");
                        parameters.Add(new DbParam("@char1", 0));
                    }
                    if (ColumnExists(CharacterID2_Ref))
                    {
                        columns.Add(CharacterID2_Ref);
                        values.Add("@char2");
                        parameters.Add(new DbParam("@char2", 0));
                    }
                    if (ColumnExists(IM_Ref))
                    {
                        columns.Add(IM_Ref);
                        values.Add("@im");
                        parameters.Add(new DbParam("@im", 0));
                    }
                    if (ColumnExists("im_bonus"))
                    {
                        columns.Add("im_bonus");
                        values.Add("@bonus");
                        parameters.Add(new DbParam("@bonus", 0));
                    }
                    if (ColumnExists(Char_Delete_Code_Ref))
                    {
                        columns.Add(Char_Delete_Code_Ref);
                        values.Add("@deleteCode");
                        parameters.Add(new DbParam("@deleteCode", string.Empty));
                    }

                    string insertQuery = "INSERT INTO " + TableName + " (" + string.Join(",", columns) + ") VALUES (" + string.Join(",", values) + ")";
                    ExecuteNonQuery(insertQuery, parameters.ToArray());

                    var created = GetDataTable(
                        "SELECT " + DataBaseID_Ref + " FROM " + TableName + " WHERE " + Username_Ref + " = @username",
                        new DbParam("@username", username));

                    uint userId;
                    if (created == null || created.Rows.Count != 1 || !uint.TryParse(created.Rows[0][DataBaseID_Ref].ToString(), out userId) || userId == 0)
                    {
                        try { ExecuteNonQuery("DELETE FROM " + TableName + " WHERE " + Username_Ref + " = @username", new DbParam("@username", username)); } catch { }
                        errorMessage = "Account could not be verified after creation";
                        DebugSystem.Write($"[UserDataBase] Registration read-back failed for '{username}'.");
                        return false;
                    }

                    // Populate the legacy character ID columns too. The Player/User classes derive
                    // these IDs from the account ID, and older login components may still read the
                    // columns directly.
                    uint char1Id = userId + 10000u;
                    uint char2Id = char1Id + 4500000u;
                    if (ColumnExists(CharacterID1_Ref))
                        ExecuteNonQuery("UPDATE " + TableName + " SET " + CharacterID1_Ref + " = @char1 WHERE " + DataBaseID_Ref + " = @uid", new DbParam("@char1", char1Id), new DbParam("@uid", userId));
                    if (ColumnExists(CharacterID2_Ref))
                        ExecuteNonQuery("UPDATE " + TableName + " SET " + CharacterID2_Ref + " = @char2 WHERE " + DataBaseID_Ref + " = @uid", new DbParam("@char2", char2Id), new DbParam("@uid", userId));

                    uint verifiedId;
                    string[] verifiedData;
                    if (!GetUserData(username, password, out verifiedId, out verifiedData) || verifiedId != userId)
                    {
                        try { ExecuteNonQuery("DELETE FROM " + TableName + " WHERE " + DataBaseID_Ref + " = @uid", new DbParam("@uid", userId)); } catch { }
                        errorMessage = "Account failed login verification after creation";
                        DebugSystem.Write($"[UserDataBase] Registration login verification failed for '{username}' (userID={userId}). Row rolled back.");
                        return false;
                    }

                    DebugSystem.Write($"[UserDataBase] New game-ready user registered: {username} (userID={userId}, char1={char1Id}, char2={char2Id})");
                    return true;
                }
                catch (Exception ex)
                {
                    DebugSystem.Write($"[UserDataBase] Registration failed for '{username}': {ex.Message}\n{ex.StackTrace}");
                    errorMessage = "Registration failed. Check the server log for details.";
                    return false;
                }
            }
        }

        public DataTable GetAllUsers()
        {
            try
            {
                string query = "SELECT " + DataBaseID_Ref + ", " + Username_Ref + ", " + Password_Ref;
                if (ColumnExists("email")) query += ", email";
                if (ColumnExists(Char_Delete_Code_Ref)) query += ", " + Char_Delete_Code_Ref + " as cipher";
                if (ColumnExists(IM_Ref)) query += ", " + IM_Ref;
                query += " FROM " + TableName + " ORDER BY " + DataBaseID_Ref;
                return GetDataTable(query);
            }
            catch (Exception ex)
            {
                DebugSystem.Write(new ExceptionData(ex));
                return null;
            }
        }

        public bool DeleteUser(int userID)
        {
            try
            {
                ExecuteNonQuery("DELETE FROM " + TableName + " WHERE " + DataBaseID_Ref + " = @id", new DbParam("@id", userID));
                DebugSystem.Write($"User deleted: ID {userID}");
                return true;
            }
            catch (Exception ex)
            {
                DebugSystem.Write(new ExceptionData(ex));
                return false;
            }
        }

        public bool UpdatePassword(int userID, string newPassword)
        {
            try
            {
                ExecuteNonQuery(
                    "UPDATE " + TableName + " SET " + Password_Ref + " = @password WHERE " + DataBaseID_Ref + " = @id",
                    new DbParam("@password", newPassword),
                    new DbParam("@id", userID));
                DebugSystem.Write($"Password updated for user ID {userID}");
                return true;
            }
            catch (Exception ex)
            {
                DebugSystem.Write(new ExceptionData(ex));
                return false;
            }
        }

        public bool OnLogin(User usr)
        {
            if (usr == null) return false;
            lock (mylock)
            {
                if (!GOnlineUsers.Any(x => x != null && x.DataBaseID == usr.DataBaseID))
                    GOnlineUsers.Add(usr);
            }
            return true;
        }

        public void OnLogOff(User usr)
        {
            if (usr == null) return;
            lock (mylock)
            {
                GOnlineUsers.RemoveAll(x => x == null || x.DataBaseID == usr.DataBaseID);
            }
        }
    }
}