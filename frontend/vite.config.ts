import {defineConfig} from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";

// Resolve the repo's `deployments/` directory so Vite can glob it during build.
const repoRoot = path.resolve(__dirname, "..");

export default defineConfig({
    plugins: [react()],
    server: {
        port: 5173,
        fs: {
            // Allow reading deploy artifacts that live outside frontend/
            allow: [".", repoRoot],
        },
    },
    resolve: {
        alias: {
            "@deployments": path.join(repoRoot, "deployments"),
        },
    },
});
