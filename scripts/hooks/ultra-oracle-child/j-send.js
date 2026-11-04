// scripts/hooks/ultra-oracle-child/j-send.js — spec §5 J-send. Origin and pathname are checked before any focus, insert or click.
(async () => {
  try {
    if (location.origin !== 'https://chatgpt.com') return 'ERR origin';
    if (location.pathname !== '/') return 'ERR not-home';
    const S = 'Follow the instructions in the attached file.';
    const ed = document.querySelector('.ProseMirror');
    const form = ed && ed.closest('form');
    if (!ed || !form) return 'ERR focus';
    ed.focus();
    if (document.activeElement !== ed) return 'ERR focus';
    document.execCommand('insertText', false, S);
    if (ed.textContent !== S) return 'ERR focus';
    const send = form.querySelector('button[aria-label="Send"]');
    if (!send || send.disabled) return 'ERR send';
    send.click();
    return 'SENT';
  } catch (e) {
    return 'ERR schema';
  }
})()
