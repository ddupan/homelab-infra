// Global (self-hosted) config. Per-repo rules live in each repo's renovate.json.
module.exports = {
  platform: 'gitea',
  // Public LE cert; inside the cluster this name resolves to Envoy on .127, not the WAN.
  endpoint: 'https://git.ddupan.top/api/v1/',
  gitAuthor: 'Renovate Bot <renovate-bot@users.noreply.ddupan.top>',
  // renovate-bot is a restricted user, so it only sees repos it was added to as a
  // collaborator — that list is the whole scope.
  autodiscover: true,
  onboardingConfig: {
    $schema: 'https://docs.renovatebot.com/renovate-schema.json',
    extends: ['config:recommended'],
  },
  // Our own hosts (e.g. the terraform.lab.ddupan.top provider registry) resolve to LAN
  // addresses; Renovate is moving to blocking internal hosts by default.
  hostRules: [{ matchHost: 'ddupan.top', allowInternal: true }],
  // Every PR runs CI on the laptop, which is already the bottleneck.
  prHourlyLimit: 2,
  prConcurrentLimit: 5,
};
