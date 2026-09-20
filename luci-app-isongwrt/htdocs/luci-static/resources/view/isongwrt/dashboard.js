'use strict';
'require view';
'require form';
'require tools.isongwrt as iso';

function btn(label, style, fn) {
	return E('button', { 'class': 'btn cbi-button cbi-button-' + style, 'click': fn }, label);
}

function row(title, field, desc) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, [
			field,
			desc ? E('div', { 'class': 'cbi-value-description' }, desc) : ''
		])
	]);
}

return view.extend({
	load: function () {
		return Promise.all([ iso.loadUci(), iso.call(['status']) ]);
	},

	render: function (data) {
		var m, s, o, self = this;
		var st = (data && data[1]) || {};
		self.apiSource = st.api_source || 'none';

		/* The sing-box API/dashboard is plain HTTP (no TLS), so the link is built
		   with an explicit http:// scheme and reads the port from the live form
		   value — editing the port must not require a save first. */
		function panelUrl() {
			var port = '';
			try {
				port = (portOpt && portOpt.formvalue('main')) || '';
			} catch (e) {
				console.warn('isongwrt: could not read the live api_port value, using the saved one', e);
			}
			if (!port)
				port = iso.get('api_port', '9090');
			return 'http://' + window.location.hostname + ':' + port + '/dashboard/';
		}

		m = new form.Map('isongwrt', '面板',
			'开启后内核自动下载并托管官方 sing-box-dashboard 于 /dashboard/（默认每天检查更新）。' +
			'监听 0.0.0.0，局域网可访问；访问密钥已自动生成。');

		s = m.section(form.NamedSection, 'main', 'isongwrt', 'API / 官方面板');

		o = s.option(form.Flag, 'dashboard', '启用官方面板');
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'api_port', '监听端口',
			'Default 9090 — change it (e.g. 9095) if another service on this device already listens there.');
		o.datatype = 'port';
		o.default = '9090';
		o.rmempty = false;
		var portOpt = o;

		o = s.option(form.Value, 'api_secret', '访问密钥',
			'浏览器打开面板时填入；留空 = 保存并应用时自动生成（刷新本页可见），也可用下方按钮重新生成。');
		o.password = true;
		var secretOpt = o;

		/* Show a freshly generated secret in place instead of reloading the page,
		   which would silently drop unsaved edits of the other fields. Setting it
		   through the widget keeps formvalue() in sync, so a later "Save & Apply"
		   writes the new secret back instead of the stale one. */
		function refreshSecretField(value) {
			var widget = secretOpt.getUIElement('main');
			if (widget && typeof widget.setValue === 'function') {
				widget.setValue(value);
				return;
			}
			/* Fallback: the rendered input carries the id "widget.<cbid>" */
			var node = document.getElementById('widget.cbid.isongwrt.main.api_secret');
			if (node) {
				node.value = value;
				return;
			}
			console.warn('isongwrt: api_secret input not found; the new secret is only stored in UCI');
		}

		o = s.option(form.Value, 'dashboard_download_url', '面板资源地址',
			'留空 = 官方 gh-pages zip；亦可手工放入工作目录的 dashboard/ 目录。');

		return m.render().then(function (mapNode) {
			var notices = [];
			if (self.apiSource === 'config')
				notices.push(E('div', { 'class': 'cbi-section' }, E('div', { 'style': 'color:#c60' },
					'检测到你的配置里已定义 API 服务：面板不会注入或覆盖它，本页「启用官方面板 / 监听端口 / 访问密钥」仅在由面板生成时才生效。')));

			var panelLink = E('a', { 'href': panelUrl(), 'target': '_blank' }, panelUrl());
			function refreshPanelLink() {
				var url = panelUrl();
				panelLink.href = url;
				panelLink.textContent = url;
			}
			/* Keep the link in sync with the port currently typed in the form */
			mapNode.addEventListener('input', refreshPanelLink);
			mapNode.addEventListener('change', refreshPanelLink);

			return E('div', {}, notices.concat([
				mapNode,
				E('div', { 'class': 'cbi-section' }, [
					row('操作', E('div', {}, [
						btn('生成新密钥', 'action', function () {
							return iso.busy(iso.call(['api-secret-new']), '生成新密钥…').then(function (r) {
								iso.notify(r, '已生成新密钥，保存并应用后生效');
								if (r && r.ok && r.secret)
									refreshSecretField(r.secret);
							});
						}),
						' ',
						btn('打开面板', 'action', function () {
							refreshPanelLink();
							window.open(panelLink.href, '_blank');
						})
					])),
					row('面板入口', panelLink,
						'浏览器首次打开需输入上方「访问密钥」；局域网内其它设备同样可访问。')
				])
			]));
		});
	},

	/* 保存/应用：弹窗式提醒（见 tools/isongwrt.js） */
	handleSave: iso.handleSave,
	handleSaveApply: iso.handleSaveApply
});
