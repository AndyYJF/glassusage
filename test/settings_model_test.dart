import 'package:flutter_test/flutter_test.dart';
import 'package:glassusage/domain/models/settings_model.dart';

// 审核范围：确保新增的小窗参数可往返保存，且旧配置缺少字段时保持默认值。
// 本文件不验证桌面捕获、原生拖动或返回主界面；这些仍需桌面运行验收。
void main() {
  test('widget glass optics persist through json round trip', () {
    final settings = AppSettings().copyWithPatch({
      'widgetRefraction': 45.5,
      'widgetChromatic': 2.5,
    });
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.widgetRefraction, 45.5);
    expect(restored.widgetChromatic, 2.5);
  });

  test('widget glass optics default when absent from old settings', () {
    final restored = AppSettings.fromJson(const {});
    expect(restored.widgetRefraction, 32.0);
    expect(restored.widgetChromatic, 1.2);
  });
}
