import {
  readFileSync,
  writeFileSync,
  mkdtempSync,
  rmSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Missing environment variable: ${name}`);
  return value;
}

const slackMode = process.env.SLACK_ENABLED ?? "false";
if (!["true", "false"].includes(slackMode)) {
  throw new Error("SLACK_ENABLED must be true or false");
}
const slackEnabled = slackMode === "true";

function slackId(name, pattern, placeholder) {
  if (!slackEnabled) return placeholder;
  const value = required(name);
  if (!pattern.test(value)) {
    throw new Error(`Invalid Slack ID: ${name}`);
  }
  return value;
}

const replacements = [
  [
    "__SLACK_WORKSPACE_ID__",
    slackId("SLACK_WORKSPACE_ID", /^T[A-Z0-9]+$/, "T0000000000"),
  ],
  [
    "__SLACK_REQUESTS_CHANNEL_ID__",
    slackId("SLACK_REQUESTS_CHANNEL_ID", /^C[A-Z0-9]+$/, "C0000000001"),
  ],
  [
    "__SLACK_APPROVALS_CHANNEL_ID__",
    slackId("SLACK_APPROVALS_CHANNEL_ID", /^C[A-Z0-9]+$/, "C0000000002"),
  ],
  [
    "__SLACK_REVIEW_CHANNEL_ID__",
    slackId("SLACK_REVIEW_CHANNEL_ID", /^C[A-Z0-9]+$/, "C0000000003"),
  ],
];

if (slackEnabled) {
  const channelIds = replacements.slice(1).map((entry) => entry[1]);
  if (new Set(channelIds).size !== 3) {
    throw new Error("Slack channels must have different IDs");
  }
  if (new URL(required("PUBLIC_WEBHOOK_URL")).protocol !== "https:") {
    throw new Error("Slack requires an HTTPS webhook URL");
  }
}

const credentials = [
  {
    id: "pJ0OOYacZadGfP1X",
    name: "Access Request App DB",
    type: "postgres",
    data: {
      host: "postgres",
      database: "access_requests",
      user: "access_worker",
      password: required("APP_DB_PASSWORD"),
      port: 5432,
      ssl: "disable",
      maxConnections: 10,
    },
  },
  {
    id: "XK25ElJWfWPchNSz",
    name: "OpenAI account",
    type: "openAiApi",
    data: {
      apiKey: required("OPENAI_API_KEY"),
      url: "https://api.openai.com/v1",
    },
  },
  {
    id: "Zw6fpAL2pNjjsb1C",
    name: "Slack account",
    type: "slackApi",
    data: {
      accessToken: slackEnabled ? required("SLACK_BOT_TOKEN") : "",
      signatureSecret: slackEnabled ? required("SLACK_SIGNING_SECRET") : "",
    },
  },
];

const credentialByType = Object.fromEntries(
  credentials.map((credential) => [credential.type, credential]),
);

const files = [
  "processor.json",
  "demo-intake.json",
  "report.json",
  "slack-intake.json",
  "notification-dispatcher.json",
];

const workflows = files.map((file) => {
  let text = readFileSync(join("/workflows", file), "utf8");
  for (const [original, configured] of replacements) {
    text = text.replaceAll(original, configured);
  }

  const original = JSON.parse(text);
  const workflow = {
    id: original.id,
    name: original.name,
    versionId: randomUUID(),
    active: false,
    nodes: original.nodes,
    connections: original.connections,
    pinData: {},
    settings: {
      ...original.settings,
      saveDataErrorExecution: "none",
      saveDataSuccessExecution: "none",
      saveManualExecutions: false,
      saveExecutionProgress: false,
    },
  };

  if (!workflow.id) throw new Error(`Missing workflow ID: ${file}`);

  for (const node of workflow.nodes) {
    for (const type of Object.keys(node.credentials ?? {})) {
      const credential = credentialByType[type];
      if (!credential) {
        throw new Error(`Unexpected credential type: ${type}`);
      }
      node.credentials[type] = {
        id: credential.id,
        name: credential.name,
      };
    }

    if (node.type === "@n8n/n8n-nodes-langchain.lmChatOpenAi") {
      const model = process.env.OPENAI_MODEL || "gpt-4.1-mini";
      node.parameters.model = {
        __rl: true,
        mode: "id",
        value: model,
      };
    }

    if (file === "demo-intake.json" && node.name === "Edit Fields") {
      for (const field of node.parameters.assignments.assignments) {
        if (field.name === "text") {
          field.value =
            "I need read-only access to Postgres in staging for 24 hours to verify a migration.";
        }
        if (field.name === "thread_ts") field.value = "";
      }
    }

    if (
      file === "notification-dispatcher.json" &&
      node.name === "Mark Notification Sent"
    ) {
      node.retryOnFail = true;
      node.maxTries = 3;
      node.waitBetweenTries = 1000;
    }
  }

  return workflow;
});

const secrets = [
  process.env.APP_DB_PASSWORD,
  process.env.OPENAI_API_KEY,
  process.env.SLACK_BOT_TOKEN,
  process.env.SLACK_SIGNING_SECRET,
  process.env.N8N_ENCRYPTION_KEY,
].filter(Boolean).sort((a, b) => b.length - a.length);

function safeOutput(text) {
  for (const secret of secrets) {
    text = text.replaceAll(secret, "[REDACTED]");
  }
  return text;
}

function run(args, expectedOutput) {
  const result = spawnSync("n8n", args, {
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 8 * 1024 * 1024,
  });
  const output = (result.stdout ?? "") + (result.stderr ?? "");
  if (
    result.error ||
    result.status !== 0 ||
    !expectedOutput.test(output)
  ) {
    console.error(safeOutput(output).slice(-5000));
    throw new Error(`n8n command failed: ${args[0]}`);
  }
  console.log(`Completed: ${args[0]}`);
}

const directory = mkdtempSync(join(tmpdir(), "access-bootstrap-"));

try {
  const credentialsPath = join(directory, "credentials.json");
  const workflowsPath = join(directory, "workflows.json");

  writeFileSync(credentialsPath, JSON.stringify(credentials), {
    mode: 0o600,
  });
  writeFileSync(workflowsPath, JSON.stringify(workflows), {
    mode: 0o600,
  });

  run(
    ["import:credentials", `--input=${credentialsPath}`],
    /Successfully imported 3 credentials/,
  );
  run(
    ["import:workflow", `--input=${workflowsPath}`],
    /Successfully imported 5 workflows/,
  );

  const enabledFiles = new Set(["processor.json"]);
  if (slackEnabled) {
    enabledFiles.add("slack-intake.json");
    enabledFiles.add("notification-dispatcher.json");
  }

  for (let index = 0; index < files.length; index++) {
    if (!enabledFiles.has(files[index])) continue;
    run(
      ["publish:workflow", `--id=${workflows[index].id}`],
      /Please restart n8n/,
    );
  }

  console.log(
    `Bootstrap completed. Slack enabled: ${slackEnabled}`,
  );
} finally {
  rmSync(directory, { recursive: true, force: true });
}
