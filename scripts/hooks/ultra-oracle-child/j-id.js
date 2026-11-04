// scripts/hooks/ultra-oracle-child/j-id.js — spec §5 J-id. Waits up to 30 s for /c/<uuid>.
(async () => {
  try {
    if (location.origin !== 'https://chatgpt.com') return 'ERR origin';
    const end = Date.now() + 30000;
    for (;;) {
      const m = /^\/c\/([0-9a-f-]{36})$/.exec(location.pathname);
      if (m) return 'UORA_ID ' + m[1];
      if (Date.now() >= end) return 'NOID';
      await new Promise((r) => setTimeout(r, 250));
    }
  } catch (e) {
    return 'ERR schema';
  }
})()
