// RevitSyncLogger.cs
// Add-in de Revit (corre DENTRO de Revit, en la maquina de cada integrante -- no en la nube).
// Objetivo: cada vez que alguien hace "Sync to Central" con exito en un modelo Revit Cloud
// Worksharing, escribe una fila CSV con metadatos de esa sincronizacion (modelo, usuario, equipo,
// fecha/hora, estado). El pipeline de PUBLICACIONES_VENTAS usa ese historico para calcular la meta
// de publicaciones (dia con >=1 sync exitoso = dia con "Modificado").
//
// Este add-in YA EXISTIA (como PUBLICACIONES_VENTAS.RevitSyncLogger, fuera de cualquier repo, solo
// en la maquina de Juan Pablo) pero tenia un defecto de origen: escribia SIEMPRE el mismo texto fijo
// "PUBLICACIONES_VENTAS" en la columna ProjectLabel, sin importar a cual proyecto (GRANJAS JESSY,
// GONVAUTO F2, etc.) perteneciera realmente el modelo. Power BI lo compensaba con una tabla de
// mapeo escrita a mano por URN dentro de Power Query -- fragil, y que habia que actualizar cada vez
// que aparecia un modelo nuevo.
//
// PROYECTO DE MODELOS CON NOMBRE REPETIDO (p.ej. "12_ARQ_NAVE.rvt" existe tanto en GRANJAS JESSY
// como en GONVAUTO F2): igual que en PLANOS_VENTAS/revit_addin_sync/SheetSync.cs, Revit no expone de
// forma confiable en que proyecto de ACC vive un modelo en la nube con solo mirar el archivo (ni la
// ruta visible ni el GUID interno del modelo sirven -- ya se probaron y descartaron alli). Para esos
// casos, este add-in pregunta (una sola vez POR MODELO, no por sincronizacion) a cual proyecto
// pertenece, usando un desplegable restringido a los proyectos candidatos reales (nunca texto
// libre), y guarda la respuesta en "_confirmaciones_proyecto.json" dentro de la carpeta compartida
// -- asi que en cuanto UNA persona confirma, todos los demas se benefician sin que les vuelva a
// preguntar.
//
// La lista de candidatos por modelo se lee de "_modelos_duplicados.json" en la misma carpeta
// compartida (mismo formato que usa collect.py en PLANOS_VENTAS: {"NOMBRE_MODELO": ["Proyecto A",
// "Proyecto B"]}). Mientras no exista un pipeline Python equivalente para PUBLICACIONES_VENTAS que
// lo genere automaticamente, este repo trae un "_modelos_duplicados.json" inicial con los modelos ya
// conocidos -- cuando ese pipeline exista (fase siguiente de la migracion), puede sobrescribir este
// archivo con datos mas completos sin tocar el codigo del add-in.
//
// Requiere (para compilar, en una maquina CON Visual Studio o .NET SDK 8 y Revit instalado):
//   - Referencias: RevitAPI.dll, RevitAPIUI.dll (de la instalacion local de Revit)
//   - Target framework: net8.0-windows (Revit 2025)
//
// Ver INSTALL.md en esta misma carpeta para compilar, y Instalador/LEEME.txt para instalar en cada
// equipo sin tocar codigo.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using WinForm = System.Windows.Forms.Form;
using WinLabel = System.Windows.Forms.Label;
using WinComboBox = System.Windows.Forms.ComboBox;
using WinComboBoxStyle = System.Windows.Forms.ComboBoxStyle;
using WinButton = System.Windows.Forms.Button;
using WinFormStartPosition = System.Windows.Forms.FormStartPosition;
using WinFormBorderStyle = System.Windows.Forms.FormBorderStyle;
using WinDialogResult = System.Windows.Forms.DialogResult;
using Autodesk.Revit.ApplicationServices;
using Autodesk.Revit.DB;
using Autodesk.Revit.DB.Events;
using Autodesk.Revit.UI;

namespace PublicacionesVentas.RevitSyncLogger
{
    public class App : IExternalApplication
    {
        public Result OnStartup(UIControlledApplication application)
        {
            application.ControlledApplication.DocumentSynchronizedWithCentral += OnAfterSync;
            return Result.Succeeded;
        }

        public Result OnShutdown(UIControlledApplication application)
        {
            application.ControlledApplication.DocumentSynchronizedWithCentral -= OnAfterSync;
            return Result.Succeeded;
        }

        // Este evento corre DESPUES de terminar un Synchronize with Central. El handler nunca debe
        // interrumpir el flujo normal de Revit, asi que cualquier fallo de registro se ignora.
        private void OnAfterSync(object sender, DocumentSynchronizedWithCentralEventArgs e)
        {
            try
            {
                var doc = e.Document;
                if (doc == null || !doc.IsModelInCloud) return;

                RegistrarSync(doc, e.Status.ToString());
            }
            catch
            {
                // Nunca interrumpir el flujo normal de Revit por un fallo de este add-in.
            }
        }

        private void RegistrarSync(Document doc, string syncStatus)
        {
            var carpeta = ResolverCarpetaLog();
            if (carpeta == null) return; // synclogger-config.txt no encontrado -- no hace nada

            var carpetaCompartida = ResolverCarpetaCompartida() ?? carpeta;
            var modelo = doc.Title ?? "modelo";
            var modelGuid = ObtenerModelGuid(doc);
            var proyecto = ResolverProyecto(carpetaCompartida, NormalizarNombreModelo(modelo), modelGuid);

            var registro = new SyncRecord
            {
                SourceType = "AutomaticAddIn",
                ProjectLabel = proyecto ?? "",
                ModelName = modelo,
                ModelUrn = TryGetString(doc, "GetCloudModelUrn"),
                RevitProjectId = TryGetString(doc, "GetProjectId"),
                RevitHubId = TryGetString(doc, "GetHubId"),
                SyncCompletedAtLocal = DateTimeOffset.Now,
                SyncStatus = syncStatus,
                RevitUser = doc.Application.Username,
                WindowsUser = WindowsIdentity.GetCurrent()?.Name ?? Environment.UserName,
                MachineName = Environment.MachineName,
                RevitVersion = doc.Application.VersionNumber
            };

            SyncCsvWriter.Append(carpeta, registro);
        }

        private static string NormalizarNombreModelo(string modelo)
        {
            var sinExtension = modelo.EndsWith(".rvt", StringComparison.OrdinalIgnoreCase)
                ? modelo.Substring(0, modelo.Length - 4)
                : modelo;
            return sinExtension.Trim().ToUpperInvariant();
        }

        private static string TryGetString(Document document, string methodName)
        {
            try
            {
                return document.GetType().GetMethod(methodName, BindingFlags.Instance | BindingFlags.Public)
                    ?.Invoke(document, null)?.ToString() ?? "";
            }
            catch
            {
                return "";
            }
        }

        // GUID del modelo en la nube (identidad del archivo, estable aunque se renombre). Se usa
        // como llave para recordar la respuesta del desplegable sin volver a preguntar cada vez.
        // Devuelve null si el modelo no es un modelo en la nube (worksharing local o no soportado).
        private string ObtenerModelGuid(Document doc)
        {
            try
            {
                if (!doc.IsWorkshared) return null;
                var centralPath = doc.GetWorksharingCentralModelPath();
                if (centralPath == null) return null;
                if (!centralPath.CloudPath) return null;
                return centralPath.GetModelGUID().ToString();
            }
            catch
            {
                return null;
            }
        }

        // Decide el "proyecto" a escribir en la fila CSV de este modelo:
        //   - Si el nombre del modelo no esta en "_modelos_duplicados.json" (no es ambiguo), no
        //     hay candidatos -- devuelve null (la fila queda con ProjectLabel vacio, igual que
        //     antes cuando no se sabia el proyecto; nunca se inventa un valor).
        //   - Si esta duplicado y ya hay una respuesta confirmada para este model_guid en
        //     "_confirmaciones_proyecto.json", la usa sin preguntar.
        //   - Si esta duplicado y no hay confirmacion (o no se pudo determinar el model_guid),
        //     pregunta con un desplegable limitado a los proyectos candidatos reales. Si la persona
        //     cancela, se guarda sin proyecto por esta vez.
        private string ResolverProyecto(string carpeta, string nombreModelo, string modelGuid)
        {
            try
            {
                var candidatos = LeerCandidatos(carpeta, nombreModelo);
                if (candidatos == null || candidatos.Count == 0) return null;

                if (modelGuid != null)
                {
                    var confirmaciones = LeerConfirmaciones(carpeta);
                    if (confirmaciones.TryGetValue(modelGuid, out var yaConfirmado) &&
                        candidatos.Contains(yaConfirmado))
                    {
                        return yaConfirmado;
                    }
                }

                var elegido = PreguntarProyecto(nombreModelo, candidatos);
                if (elegido != null && modelGuid != null)
                {
                    GuardarConfirmacion(carpeta, modelGuid, elegido);
                }
                return elegido;
            }
            catch
            {
                return null;
            }
        }

        // Lee "_modelos_duplicados.json" -- {"NOMBRE_MODELO": ["Proyecto_A", "Proyecto_B"], ...} --
        // en la carpeta compartida. Devuelve null si el modelo no aparece ahi (no es ambiguo) o el
        // archivo no existe todavia.
        private List<string> LeerCandidatos(string carpeta, string nombreModelo)
        {
            var ruta = Path.Combine(carpeta, "_modelos_duplicados.json");
            if (!File.Exists(ruta)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(ruta));
            if (!doc.RootElement.TryGetProperty(nombreModelo, out var arr)) return null;
            return arr.EnumerateArray().Select(x => x.GetString()).Where(s => s != null).ToList();
        }

        // Lee "_confirmaciones_proyecto.json" -- {"model_guid": "Proyecto", ...} -- que este mismo
        // add-in va llenando conforme la gente confirma. Compartido entre todos (vive en la misma
        // carpeta que los CSV), asi que una sola confirmacion sirve para todos.
        private Dictionary<string, string> LeerConfirmaciones(string carpeta)
        {
            var ruta = Path.Combine(carpeta, "_confirmaciones_proyecto.json");
            if (!File.Exists(ruta)) return new Dictionary<string, string>();
            try
            {
                return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(ruta))
                       ?? new Dictionary<string, string>();
            }
            catch
            {
                return new Dictionary<string, string>();
            }
        }

        private void GuardarConfirmacion(string carpeta, string modelGuid, string proyecto)
        {
            var ruta = Path.Combine(carpeta, "_confirmaciones_proyecto.json");
            for (int intento = 0; intento < 3; intento++)
            {
                try
                {
                    var actual = LeerConfirmaciones(carpeta);
                    actual[modelGuid] = proyecto;
                    var tmp = ruta + ".tmp";
                    File.WriteAllText(tmp, JsonSerializer.Serialize(actual), new UTF8Encoding(false));
                    File.Copy(tmp, ruta, overwrite: true);
                    File.Delete(tmp);
                    return;
                }
                catch
                {
                    System.Threading.Thread.Sleep(300);
                }
            }
        }

        // Ventana simple: nombre del modelo + lista de proyectos candidatos (nunca texto libre,
        // para minimizar errores de dedo). Devuelve null si la persona cierra/cancela.
        private string PreguntarProyecto(string nombreModelo, List<string> candidatos)
        {
            using var form = new WinForm
            {
                Text = "PUBLICACIONES_VENTAS -- confirmar proyecto",
                Width = 420,
                Height = 200,
                StartPosition = WinFormStartPosition.CenterScreen,
                FormBorderStyle = WinFormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false,
                TopMost = true,
            };

            var label = new WinLabel
            {
                Text = $"El modelo \"{nombreModelo}\" existe en mas de un proyecto.\n" +
                       "¿A cual proyecto pertenece ESTE archivo?\n" +
                       "(Solo se pregunta una vez por modelo.)",
                Left = 15,
                Top = 15,
                Width = 380,
                Height = 60,
            };

            var combo = new WinComboBox
            {
                Left = 15,
                Top = 80,
                Width = 380,
                DropDownStyle = WinComboBoxStyle.DropDownList,
            };
            combo.Items.AddRange(candidatos.Cast<object>().ToArray());
            combo.SelectedIndex = 0;

            var btnOk = new WinButton { Text = "Aceptar", Left = 220, Top = 120, Width = 80, DialogResult = WinDialogResult.OK };
            var btnCancel = new WinButton { Text = "Cancelar", Left = 310, Top = 120, Width = 85, DialogResult = WinDialogResult.Cancel };

            form.Controls.Add(label);
            form.Controls.Add(combo);
            form.Controls.Add(btnOk);
            form.Controls.Add(btnCancel);
            form.AcceptButton = btnOk;
            form.CancelButton = btnCancel;

            var resultado = form.ShowDialog();
            if (resultado != WinDialogResult.OK) return null;
            return combo.SelectedItem as string;
        }

        // La carpeta de destino se lee de "synclogger-config.txt" (una sola linea con la ruta) que
        // debe vivir junto al .dll, dentro de %AppData%\Autodesk\Revit\Addins\<version>\ -- mismo
        // mecanismo que sheetsync-config.txt en PLANOS_VENTAS. Asi cada usuario la configura una
        // vez al instalar (via Instalador\instalar.bat), sin tocar codigo.
        private string ResolverCarpetaLog()
        {
            try
            {
                var addinDir = Path.GetDirectoryName(typeof(App).Assembly.Location);
                var cfgPath = Path.Combine(addinDir ?? "", "synclogger-config.txt");
                if (!File.Exists(cfgPath)) return null;

                var carpeta = File.ReadAllText(cfgPath).Trim();
                if (string.IsNullOrEmpty(carpeta)) return null;

                if (!Directory.Exists(carpeta))
                    Directory.CreateDirectory(carpeta);

                return carpeta;
            }
            catch
            {
                return null;
            }
        }

        // Carpeta COMPARTIDA entre SheetSync (PLANOS_VENTAS) y RevitSyncLogger (PUBLICACIONES_VENTAS)
        // para "_modelos_duplicados.json" y "_confirmaciones_proyecto.json" -- asi una respuesta dada
        // en cualquiera de los dos add-ins sirve para ambos, en vez de preguntar dos veces por el
        // mismo modelo. Se lee de "carpeta-compartida-config.txt" (mismo mecanismo que
        // synclogger-config.txt), escrito por Instalador\instalar.bat. Si no existe (instalador
        // viejo, sin actualizar), se usa la carpeta de logs propia como respaldo -- igual que se
        // comportaba antes de este cambio.
        private string ResolverCarpetaCompartida()
        {
            try
            {
                var addinDir = Path.GetDirectoryName(typeof(App).Assembly.Location);
                var cfgPath = Path.Combine(addinDir ?? "", "carpeta-compartida-config.txt");
                if (!File.Exists(cfgPath)) return null;

                var carpeta = File.ReadAllText(cfgPath).Trim();
                if (string.IsNullOrEmpty(carpeta)) return null;

                if (!Directory.Exists(carpeta))
                    Directory.CreateDirectory(carpeta);

                return carpeta;
            }
            catch
            {
                return null;
            }
        }
    }

    internal sealed class SyncRecord
    {
        public string SourceType;
        public string ProjectLabel;
        public string ModelName;
        public string ModelUrn;
        public string RevitProjectId;
        public string RevitHubId;
        public DateTimeOffset SyncCompletedAtLocal;
        public string SyncStatus;
        public string RevitUser;
        public string WindowsUser;
        public string MachineName;
        public string RevitVersion;
    }

    internal static class SyncCsvWriter
    {
        private const string Header = "SourceType,ProjectLabel,ModelName,ModelUrn,RevitProjectId,RevitHubId,SyncCompletedAtLocal,SyncStatus,RevitUser,WindowsUser,MachineName,RevitVersion";

        // Un archivo por maquina+usuario (igual que antes) para que nunca haya dos procesos de
        // Revit escribiendo el mismo archivo a la vez.
        public static void Append(string carpeta, SyncRecord record)
        {
            Directory.CreateDirectory(carpeta);
            var fileName = $"revit_sync_{Safe(record.MachineName)}_{Safe(record.WindowsUser)}.csv";
            var path = Path.Combine(carpeta, fileName);
            var values = new[]
            {
                record.SourceType, record.ProjectLabel, record.ModelName, record.ModelUrn,
                record.RevitProjectId, record.RevitHubId,
                record.SyncCompletedAtLocal.ToString("O", CultureInfo.InvariantCulture),
                record.SyncStatus, record.RevitUser, record.WindowsUser, record.MachineName, record.RevitVersion
            };
            var line = string.Join(",", values.Select(Escape));

            for (var attempt = 0; attempt < 3; attempt++)
            {
                try
                {
                    var newFile = !File.Exists(path) || new FileInfo(path).Length == 0;
                    using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
                    using var writer = new StreamWriter(stream, new UTF8Encoding(false));
                    if (newFile) writer.WriteLine(Header);
                    writer.WriteLine(line);
                    return;
                }
                catch (IOException) when (attempt < 2)
                {
                    System.Threading.Thread.Sleep(200);
                }
            }
        }

        private static string Escape(string value) => "\"" + (value ?? "").Replace("\"", "\"\"") + "\"";
        private static string Safe(string value) => string.Concat((value ?? "unknown").Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));
    }
}
