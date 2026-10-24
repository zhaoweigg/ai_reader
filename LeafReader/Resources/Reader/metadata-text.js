// Foliate metadata values are strings, language maps ({ en: '…' }) or
// contributor objects ({ name }); both the reader and the metadata probe
// flatten them the same way.
export const languageText = value => typeof value === 'string' ? value : value ? languageText(Object.values(value)[0]) : '';
export const contributor = value => Array.isArray(value) ? value.map(contributor).filter(Boolean).join(', ')
    : typeof value === 'string' ? value : languageText(value?.name);
