'use strict';
'require view';
'require dom';
'require ui';
'require tools.isongwrt as iso';

function field(title, input, desc) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, [ input,
			desc ? E('div', { 'class': 'cbi-value-description' }, desc) : '' ])
	]);
}

return view.extend({
	load: function () {
		return Promise.all([ iso.loadUci(), iso.call(['status']) ]);
	},

	render: function (data) {
		this.status = data[1] || {};
		this.cfg = {
			api_listen: iso.get('api_listen', '127.0.0.1'),
			api_port: iso.get('api_port', '9090'),
			api_secret: iso.get('api_secret', ''),
			dashboard: iso.get('dashboard', '1') === '1',
			clash_api: iso.get('clash_api', '0') === '1',
			clash_port: iso.get('clash_port', '9091'),
			clash_secret: iso.get('clash_secret', ''),
			dashboard_download_url: iso.get('dashboard_download_url', '')
		};
		this.root = E('div', { 'class': 'cbi-map' });
		this.paint();
		return this.root;
	},

	save: function () {
		var self = this, c = this.cfg;
		iso.set('api_listen', c.api_listen);
		iso.set('api_port', c.api_port);
		iso.set('api_secret', c.api_secret);
		iso.set('dashboard', c.dashboard ? '1' : '0');
		iso.set('clash_api', c.clash_api ? '1' : '0');
		iso.set('clash_port', c.clash_port);
		iso.set('clash_secret', c.clash_secret);
		iso.set('dashboard_download_url', c.dashboard_download_url);
		return iso.applyUci().then(function () {
			return iso.busy(iso.call(['api-sync']), '生成 API 分片并校验…');
		}).then(function (r) {
			iso.notify(r, 'API 分片已更新');
			if (r && r.ok)
				return iso.busy(iso.call(['service', 'restart']), '重启服务…').then(function (r2) {
					iso.notify(r2, '服务已重启');
					return iso.call(['status']).then(function (st) { self.status = st || {}; self.paint(); });
				});
		});
	},

	paint: function () {
		var self = this, c = this.cfg, st = this.status || {};
		var url = window.location.protocol + '//' + window.location.hostname + ':' + c.api_port + '/dashboard/';
		dom.content(this.root, [
			E('h2', {}, '面板（Dashboard）'),
			E('div', { 'class': 'cbi-map-descr' },
				'sing-box 1.14+ 内置 API 服务：开启后会从官方仓库自动下载 sing-box-dashboard 并在 /dashboard/ 提供，随内核一起更新（默认每天检查）。API 与面板均由内核自身托管，无需额外安装前端包。'),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'API / 官方面板'),
				field('启用面板', E('input', {
					'type': 'checkbox', 'checked': c.dashboard ? '' : null,
					'change': ui.createHandlerFn(this, function (ev) { this.cfg.dashboard = ev.target.checked; })
				}), '关闭后仅保留其它 API 功能（若同时未启用 Clash API，则自动移除 API 分片文件）'),
				field('监听地址', E('input', {
					'type': 'text', 'class': 'cbi-input-text', 'value': c.api_listen,
					'input': ui.createHandlerFn(this, function (ev) { this.cfg.api_listen = ev.target.value; })
				}), '127.0.0.1 = 仅本机；0.0.0.0 = 允许局域网访问面板（请同时设置访问密钥）'),
				field('监听端口', E('input', {
					'type': 'text', 'class': 'cbi-input-text', 'value': c.api_port,
					'input': ui.createHandlerFn(this, function (ev) { this.cfg.api_port = ev.target.value; })
				})),
				field('访问密钥', E('input', {
					'type': 'text', 'class': 'cbi-input-text', 'value': c.api_secret,
					'input': ui.createHandlerFn(this, function (ev) { this.cfg.api_secret = ev.target.value; })
				}), '客户端以 Authorization: Bearer <secret> 认证；面板登录时填写此密钥'),
				field('面板资源下载地址', E('input', {
					'type': 'text', 'class': 'cbi-input-text', 'value': c.dashboard_download_url,
					'placeholder': '留空 = 官方 gh-pages zip',
					'input': ui.createHandlerFn(this, function (ev) { this.cfg.dashboard_download_url = ev.target.value; })
				}), 'CN 网络下载慢时可填镜像地址；也可手工把面板文件放入 工作目录/dashboard/（非空且无 .etag 时按原样提供、不再自动更新）')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '可选：Clash API（zashboard / metacubexd 等面板）'),
				field('启用 Clash API', E('input', {
					'type': 'checkbox', 'checked': c.clash_api ? '' : null,
					'change': ui.createHandlerFn(this, function (ev) { this.cfg.clash_api = ev.target.checked; })
				}), '官方 dashboard 使用 gRPC API；Clash 协议面板需要这一项'),
				field('Clash 端口', E('input', {
					'type': 'text', 'class': 'cbi-input-text', 'value': c.clash_port,
					'input': ui.createHandlerFn(this, function (ev) { this.cfg.clash_port = ev.target.value; })
				})),
				field('Clash 密钥', E('input', {
					'type': 'text', 'class': 'cbi-input-text', 'value': c.clash_secret,
					'input': ui.createHandlerFn(this, function (ev) { this.cfg.clash_secret = ev.target.value; })
				}))
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, function () { return this.save(); })
				}, '保存并应用'),
				E('a', { 'class': 'btn cbi-button', 'href': url, 'target': '_blank', 'style': 'margin-left:1em' },
					'打开面板（' + url + '）'),
				E('button', {
					'class': 'btn cbi-button', 'style': 'margin-left:1em',
					'click': ui.createHandlerFn(this, function () {
						return iso.busy(iso.call(['service', 'restart']), '重启服务…').then(function (r) {
							iso.notify(r, '服务已重启');
						});
					})
				}, '重启服务')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '状态'),
				E('p', {}, '内核：' + (st.version || '未安装') + '　运行：' + (st.running ? '是' : '否')
					+ '　API：' + (st.api || '-') + '　面板分片：' + (st.dashboard ? '已启用' : '未启用'))
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
