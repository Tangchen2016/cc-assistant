import { createRoot } from "react-dom/client";
import Home from "../../app/page";
import "../../app/globals.css";
import "../../app/desktop.css";

window.__SUBSCRIPTION_DESKTOP__ = true;
const root = document.getElementById("root");
if (!root) throw new Error("App mount point is missing");
createRoot(root).render(<Home />);
