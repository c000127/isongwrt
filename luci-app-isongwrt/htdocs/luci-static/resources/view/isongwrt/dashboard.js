'use strict';
'require view';
'require form';
'require ui';
'require tools.isongwrt as iso';

return view.extend({
	load: function () {
		return iso.loadUci();
	},

	render: function () {
		var m, s, o, self = this;

		function panelUrl() {
			var port = iso.get('api_port', '9090');
			return window.location.protocol + '//' + window.location.hostname + ':' + port + '/dashboard/';
		}

		function regenSecret() {
			return iso.busy(iso.call(['api-secret-new']), '生成新密钥…').then(function (r) {
				iso.notify(r, '已生成新访问密钥（保存并应用后生效）');
				return iso.call(['status']);
			}).then(function () {
				window.location.reload();
			});
		}

		m = new form.Map('isongwrt', '面板（Dashboard）',
			'sing-box 1.14+ 内置 API 服务：开启后内核自动下载官方 sing-box-dashboard 并在 ' +
			'/dashboard/ 提供，随内核更新（默认每天检查）。监听地址固定为 0.0.0.0（局域网可访问），' +
			'访问密钥已自动生成。设置改动后请「保存并应用」。');

		s = m.section(form.NamedSection, 'main', 'isongwrt', 'API / 官方面板');
		s.anonymous = true;

		o = s.option(form.Flag, 'dashboard', '启用官方面板',
			'关闭后仅保留其它 API 功能；若同时未启用 Clash API，将移除 API 分片文件。');
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'api_port', '监听端口',
			'默认 9090 与 mihomo/nikki 的 Clash API 相同，同机部署请改为其它端口（如 9095）。');
		o.datatype = 'port';
		o.default = '9090';
		o.rmempty = false;

		o = s.option(form.Value, 'api_secret', '访问密钥',
			'面板登录与 API 客户端使用（Authorization: Bearer）。已默认生成，可点右侧按钮重新生成。');
		o.rmempty = false;

		o = s.option(form.Button, 'regen');
		o.inputstyle = 'action';
		o.inputtitle = '生成新密钥';
		o.onclick = regenSecret;

		o = s.option(form.Value, 'dashboard_download_url', '面板资源下载地址',
			'留空 = 官方 gh-pages zip；网络受限可填镜像。也可手工把面板文件放入工作目录的 dashboard/ ' +
			'（非空且无 .etag 时按原样提供、不再自动更新）。');

		s = m.section(form.NamedSection, 'main', 'isongwrt', '可选：Clash API（zashboard / metacubexd）');
		s.anonymous = true;

		o = s.option(form.Flag, 'clash_api', '启用 Clash API',
			'官方 dashboard 走 gRPC API；Clash 协议面板（zashboard 等）需要这一项。');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'clash_port', 'Clash 端口');
		o.datatype = 'port';
		o.default = '9091';
		o.rmempty = false;

		o = s.option(form.Value, 'clash_secret', 'Clash 密钥');
		o.rmempty = false;

		s = m.section(form.TableSection, 'info', '面板入口');
		s.anonymous = true;
		o = s.option(form.DummyValue, '_url');
		o.cfgvalue = function () {
			var url = panelUrl();
			return E('div', {}, [
				E('a', { 'href': url, 'target': '_blank' }, url),
				E('div', { 'class': 'cbi-value-description' },
					'浏览器首次打开需输入上方「访问密钥」；局域网内其它设备同样可访问。')
			]);
		};

		return m.render();
	}
});
