import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/plan_ui.dart';

void main() {
  test('the yearly plan saves about a sixth over twelve monthly payments', () {
    expect(PlanPrices.yearlySaving.toStringAsFixed(2), '11.89');
    expect(PlanPrices.yearlySavingPercent, 17);
    expect(PlanPrices.yearlyPerMonth, '5.00');
  });
}
