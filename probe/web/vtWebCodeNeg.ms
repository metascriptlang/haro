// Negative control of vtWebCode.ms: it expects "hellx", so the exit status must be 24.
import { checkVt } from "./vtWebCheck";

process.exit(checkVt("hellx"));
