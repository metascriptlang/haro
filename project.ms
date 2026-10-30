import { Project, Target, Artifact, Platform, Arch, Slot } from "../ion/tooling/generator/description";
import { bundlePrefix } from "../ion/tooling/generator/plugins";

function conpty(file: string): Artifact {
	return {
		name: file,
		license: "MIT",
		slices: [{ platform: Platform.Windows, arch: Arch.X64, files: ["vendor/conpty/x64/" + file] }],
	};
}

export const project: Project = {
	name: "Haro",
	targets: [{
		...Target.windowsApp("Haro", "src/app/haro.ms"),
		files: [
			{ artifact: conpty("conpty.dll"), slot: Slot.Libraries, directory: "" },
			{ artifact: conpty("OpenConsole.exe"), slot: Slot.Executables, directory: "" },
		],
	}],
	plugins: [bundlePrefix("dev.haro")],
};
