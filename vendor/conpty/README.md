# ConPTY host

`x64/conpty.dll` and `x64/OpenConsole.exe` are unmodified from the NuGet package
`Microsoft.Windows.Console.ConPTY` 1.25.260930003 (MIT, `LICENSE`), both signed by Microsoft
Corporation. `project.ms` places them beside `Haro.exe`, where `src/pty/conpty.c` loads the DLL;
a build without them falls back to the inbox conhost.
