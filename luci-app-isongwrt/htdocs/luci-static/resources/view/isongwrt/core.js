'use strict';
'require view';
'require form';
'require dom';
'require ui';
'require uci';
'require tools.isongwrt as iso';

var CHANNELS = [ 'stable', 'rc', 'beta', 'alpha' ];

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
		return Promise.all([ iso.call(['installed']), iso.call(['channels', 'cached']) ]);
	},

	render: function (data) {
		var m, s, o, self = this;
		self.installed = data[0] || {};
		self.channels = null;
		self.fetchedAtText = '';
		self.staleWarning = '';
		var cached = data[1] || {};
		if (cached.ok && cached.cached) {
			self.channels = cached.channels || [];
			self.fetchedAtText = cached.fetched_at_text || '';
		}

		/* 说明文字：与表格/正文同左边界（不用 cbi-section-descr，它自带 1.25rem 左内边距） */
		function note(text, top) {
			return E('div', {
				'style': 'color:#888;font-size:small;line-height:1.5;margin:' + (top || '.35rem') + ' 0 0'
			}, text);
		}

		/* ---- 视图自持的动态节点（不走 form.DummyValue，避免表单渲染差异） ---- */
		self.latestInner = E('div', {}, E('em', {}, '未检查'));
		self.installedInner = E('div', {});

		function paintLatest() {
			if (!self.channels) {
				dom.content(self.latestInner, E('div', { 'style': 'padding:.25rem 0' }, [
					E('em', {}, '尚未检查。'),
					note('点上方「检查更新」从官方 Releases（SagerNet/sing-box）读取各渠道最新版本与更新状态。')
				]));
				return;
			}
			var active = (self.installed || {}).active || '';
			var rows = [ E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, '渠道'),
				E('th', { 'class': 'th' }, '最新版本'),
				E('th', { 'class': 'th' }, '状态')
			]) ];
			self.channels.forEach(function (c) {
				var latest = c.latest || '';
				var state;
				if (!latest)
					state = E('span', { 'style': 'color:#888' }, '该渠道近期无版本（可用「指定版本」直接填 tag）');
				else if (active && latest.replace(/^v/, '') === active)
					state = E('span', { 'style': 'color:green' }, '已安装');
				else if (active)
					state = E('span', {}, '有更新');
				else
					state = E('span', { 'style': 'color:#888' }, '未安装');
				rows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, E('strong', {}, c.name)),
					E('td', { 'class': 'td left' }, latest || '—'),
					E('td', { 'class': 'td left' }, state)
				]));
			});
			dom.content(self.latestInner, E('div', {}, [
				self.staleWarning ? E('div', { 'style': 'color:#c60;margin:.25rem 0' }, '⚠ ' + self.staleWarning + '（' + (self.fetchedAtText || '') + '）') : '',
				E('table', { 'class': 'table' }, rows),
				note('来源：官方 Releases' + (self.fetchedAtText ? '（上次检查：' + self.fetchedAtText + '）' : '') +
					'；安装按上方「渠道」选择执行（点「安装 / 升级」时会自动先保存设置）。')
			]));
		}

		function installedTable() {
			var versions = (self.installed.versions || []);
			if (!versions.length)
				return E('div', { 'style': 'padding:.25rem 0' }, [
					E('em', {}, '尚未安装内核。'),
					note('点上方「安装 / 升级」从官方 Releases 下载安装（视网络约 30–90 MB）；也可在「配置管理」中导入配置。')
				]);

			var rows = [ E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, '版本'),
				E('th', { 'class': 'th' }, '大小'),
				E('th', { 'class': 'th' }, '操作')
			]) ];

			versions.forEach(function (v) {
				var isActive = (v.version === self.installed.active);
				var actions = [];
				if (isActive) {
					actions.push(E('em', {}, '当前激活'));
				} else {
					actions.push(btn('激活', 'apply', function () {
						return iso.busy(iso.call([ 'activate', v.version ]), '切换内核…').then(function (r) {
							iso.notify(r, '已切换到 ' + v.version);
							return reload();
						});
					}), ' ');
				}
				actions.push(btn('删除', 'remove', function () { return doRemove(v.version, isActive); }));

				rows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, v.version + (isActive ? ' ★' : '')),
					E('td', { 'class': 'td left' }, v.size ? (Math.round(v.size / 1048576 * 10) / 10) + ' MiB' : '—'),
					E('td', { 'class': 'td left' }, actions)
				]));
			});

			return E('div', {}, [
				E('table', { 'class': 'table' }, rows),
				note('★ = 当前激活；「激活」立即切换并重启服务；删除当前激活版本会先确认（若还有其它版本，将自动切换到其中最新的一版）。')
			]);
		}

		function paintInstalled() {
			dom.content(self.installedInner, installedTable());
		}

		function doRemove(version, isActive) {
			function run() {
				var args = isActive ? [ 'remove', version, 'force' ] : [ 'remove', version ];
				return iso.busy(iso.call(args), '删除内核…').then(function (r) {
					if (r && r.ok) {
						var msg = '已删除 ' + version;
						if (r.activated) msg += '，已自动切换到 ' + r.activated;
						else if (r.activated === null) msg += '（已无可用内核，服务将无法启动）';
						iso.notify({ ok: true }, msg);
					} else {
						iso.notify(r, '');
					}
					return reload();
				});
			}
			if (!isActive) return run();
			ui.showModal('删除当前激活的内核', [
				E('p', {}, '「' + version + '」是当前激活的内核。删除后会停止服务；若还有其它版本，将自动切换到其中最新的一版。'),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, '取消'),
					' ',
					E('button', { 'class': 'btn cbi-button-negative', 'click': function () { ui.hideModal(); return run(); } }, '确认删除')
				])
			]);
			return Promise.resolve();
		}

		function reload() {
			return iso.call(['installed']).then(function (r) {
				self.installed = r || {};
				paintInstalled();
				paintLatest();
			});
		}

		function checkUpdates() {
			return iso.busy(iso.call(['channels', 'force']), '正在检查官方 Releases…').then(function (r) {
				if (r && r.ok) {
					self.channels = r.channels || [];
					self.staleWarning = r.stale ? (r.warning || '刷新失败，以下为上次结果') : '';
					self.fetchedAtText = r.stale ? (r.fetched_at_text || '') : '刚刚';
					paintLatest();
					return;
				}
				iso.notify(r, '');
			});
		}

		/* 读取表单控件的“实时值”（section_id='main'，见 form.NamedSection），
		   避免“改了渠道但没保存并应用”时仍按旧值安装 */
		function liveValue(opt) {
			try {
				var v = opt && opt.formvalue('main');
				if (v !== null && v !== undefined && v !== '')
					return v;
			} catch (e) {
				/* Falling back to the saved value is intended, but keep it diagnosable */
				console.warn('isongwrt: cannot read the live form value, falling back to the saved value', e);
			}
			return null;
		}

		function currentChannel() {
			var v = liveValue(channelOpt);
			return (v != null) ? v : iso.get('channel', 'stable');
		}

		function currentPin() {
			var v = liveValue(pinOpt);
			return ((v != null) ? v : (iso.get('pin_version', '') || '')).trim();
		}

		/* 把当前表单提交到 UCI（等价「保存并应用」中的提交动作；失败时回退实时值） */
		function persistSettings() {
			var prep = Promise.resolve();
			try {
				if (typeof self.handleSave === 'function')
					prep = Promise.resolve(self.handleSave(null)).then(function () { return uci.apply(); });
			} catch (e) {
				console.warn('isongwrt: saving the settings before install failed, using the live values', e);
				prep = Promise.resolve();
			}
			return prep.catch(function (e) {
				console.warn('isongwrt: saving the settings before install failed, using the live values', e);
			});
		}

		function install() {
			return persistSettings().then(function () { return doInstall(); });
		}

		function doInstall() {
			var ch = currentChannel();
			var pin = currentPin();
			var label = pin || (ch + ' 渠道最新版');
			var pre = E('pre', {
				'style': 'max-height:40vh;overflow:auto;white-space:pre-wrap;font-size:12px;background:#111;color:#ddd;padding:8px'
			}, '正在启动安装任务…');
			var fail = E('div', { 'style': 'color:#c60;margin:.5rem 0 0;display:none' }, '');

			var timer = null, polls = 0;
			function stop() { if (timer) { clearInterval(timer); timer = null; } }

			/* Terminal state: stop polling and leave the log on screen to be read */
			function finish(msg) {
				stop();
				fail.textContent = msg;
				fail.style.display = '';
				return reload();
			}

			ui.showModal('安装 ' + label, [ pre, fail, E('div', { 'class': 'right' }, [
				/* Closing the window must stop the poller as well */
				E('button', { 'class': 'btn', 'click': function () { stop(); ui.hideModal(); } }, '关闭')
			]) ]);

			function pollInstall() {
				return iso.call(['install-status']).then(function (r) {
					pre.textContent = (r && r.log) || '(无输出)';
					pre.scrollTop = pre.scrollHeight;
					polls++;

					/* Unparsable status (ctl failed, empty output): never poll forever */
					if (!r || r.ok === false)
						return finish('❌ 无法读取安装状态：' + ((r && r.error) || '未知错误'));

					if (r.state === 'done') {
						stop(); ui.hideModal();
						iso.notify({ ok: true }, '安装完成');
						return reload();
					}
					if (r.state === 'failed')
						return finish('❌ 安装失败，详见上方日志');
					/* idle = no installer process and no result in the log: the task
					   died without reporting. Tolerate it on the first poll only —
					   the background job may not have written its lock file yet. */
					if (r.state === 'idle' && polls > 1)
						return finish('❌ 安装任务已不在运行（idle），可能被中断，详见上方日志');
				});
			}

			return iso.call(pin ? [ 'install-bg', ch, pin ] : [ 'install-bg', ch ]).then(function (r) {
				if (!r || !r.ok) { stop(); ui.hideModal(); iso.notify(r, ''); return; }
				timer = setInterval(pollInstall, 3000);
				return pollInstall();
			});
		}

		/* ---- 表单：仅设置项 ---- */
		m = new form.Map('isongwrt', '内核管理',
			'内核取自官方 Releases（SagerNet/sing-box），按本机架构自动匹配、优先 musl 构建；本项目不编译内核。点「安装 / 升级」会自动先保存当前设置。');

		s = m.section(form.NamedSection, 'main', 'isongwrt', '安装设置');

		o = s.option(form.ListValue, 'channel', '渠道');
		CHANNELS.forEach(function (c) { o.value(c, c); });
		o.default = 'stable';
		var channelOpt = o;

		o = s.option(form.Value, 'pin_version', '指定版本',
			'留空 = 渠道最新；也可填精确 tag，如 v1.15.0-alpha.5。');
		var pinOpt = o;

		o = s.option(form.Value, 'github_proxy', '加速前缀',
			'留空 = 直连 github.com；受限网络可填如 https://ghfast.top/');

		paintLatest();
		paintInstalled();

		return m.render().then(function (mapNode) {
			return E('div', {}, [
				mapNode,
				E('div', { 'class': 'cbi-section' }, [
					row('操作', E('div', {}, [
						btn('检查更新', 'action', checkUpdates),
						' ',
						btn('安装 / 升级', 'apply', install),
						' ',
						btn('回滚', 'reset', function () {
							return iso.busy(iso.call(['rollback']), '回滚内核…').then(function (r) {
								iso.notify(r, '已回滚');
								return reload();
							});
						})
					]))
				]),
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, '各分支最新版本'), self.latestInner
				]),
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, '已安装版本'), self.installedInner
				])
			]);
		});
	},

	/* 保存/应用：弹窗式提醒（见 tools/isongwrt.js） */
	handleSave: iso.handleSave,
	handleSaveApply: iso.handleSaveApply
});
