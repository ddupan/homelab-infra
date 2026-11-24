// go.ddupan.top: Go vanity import paths. `go get go.ddupan.top/<module>/...` fetches
// `?go-get=1` and reads the go-import meta tag; browsers are redirected to the repository.
// MODULES (a JSON binding from go-vanity.tf) maps the first path segment to its repository.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const name = url.pathname.split('/')[1];
    // hasOwn: a name like `constructor` must not resolve through the prototype.
    const repo = Object.hasOwn(env.MODULES, name) ? env.MODULES[name] : undefined;
    if (!repo) return new Response('not found\n', { status: 404 });
    if (url.searchParams.get('go-get') !== '1') return Response.redirect(repo, 302);
    const prefix = `${url.host}/${name}`;
    const html = `<!doctype html><html><head><meta charset="utf-8">
<meta name="go-import" content="${prefix} git ${repo}.git">
<meta name="go-source" content="${prefix} ${repo} ${repo}/tree/main{/dir} ${repo}/blob/main{/dir}/{file}#L{line}">
</head><body>${prefix}</body></html>
`;
    return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8' } });
  },
};
