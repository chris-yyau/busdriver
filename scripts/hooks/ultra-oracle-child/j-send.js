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
    // ChatGPT keeps the home composer's draft across sessions, even after a send (live r1), so a
    // previous consult leaves exactly S behind. Only that exact sentence is ours to clear; any other
    // draft is someone else's and is never inserted beside or deleted. Once the composer is proven
    // empty, a failure clears only the sentence we inserted.
    const clear = () => { document.execCommand('selectAll', false); document.execCommand('delete', false); };
    const cur = String(ed.textContent || '');
    if (cur === S) clear();
    else if (cur !== '') return 'ERR draft';
    if (String(ed.textContent || '') !== '') return 'ERR draft';
    document.execCommand('insertText', false, S);
    if (ed.textContent !== S) { clear(); return 'ERR focus'; }
    const send = form.querySelector('button[aria-label="Send"]');
    if (!send || send.disabled) { clear(); return 'ERR send'; }
    send.click();
    return 'SENT';
  } catch (e) {
    return 'ERR schema';
  }
})()
