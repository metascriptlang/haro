// Run under node with no output: the exit status is the result, 0 = every check passed.
import { checkVt } from "./vtWebCheck";

process.exit(checkVt("hello"));
