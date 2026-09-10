using System;
using System.IO;
using System.Windows.Forms;

namespace Wonderland_Private_Server {

    static class Program {
        /// <summary>
        /// The main entry point for the application.
        /// </summary>
        [STAThread]

        static void Main() {
            EnsureDatabaseOverride();

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new Form1());

        }

        /// <summary>
        /// Keeps the runtime database override synchronized with the database that belongs
        /// to this server checkout. This prevents stale bin\Debug overrides from pointing at
        /// an old server folder after the repository has been moved or renamed.
        /// </summary>
        private static void EnsureDatabaseOverride() {
            try {
                string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                string projectDb = Path.GetFullPath(Path.Combine(baseDir, "..", "..", "Data", "ServerDataBase.db"));

                if (!File.Exists(projectDb))
                    return;

                string overridePath = Path.Combine(baseDir, "database.override.txt");
                string contents =
                    "Type|1" + Environment.NewLine +
                    "User|" + Environment.NewLine +
                    "Pass|" + Environment.NewLine +
                    "DB|" + Environment.NewLine +
                    "Port|" + Environment.NewLine +
                    "IP|" + Environment.NewLine +
                    "File|" + projectDb + Environment.NewLine;

                File.WriteAllText(overridePath, contents);
            }
            catch {
                // Database initialization will report a useful error if resolution still fails.
            }
        }
    }
}
