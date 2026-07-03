<?php

namespace Database\Factories;

use App\Models\Counter;
use Illuminate\Database\Eloquent\Factories\Factory;

class CounterFactory extends Factory
{
    /**
     * The name of the factory's corresponding model.
     *
     * @var string
     */
    protected $model = Counter::class;

    /**
     * Create a new factory instance for the model.
     *
     * @return Factory
     */
    protected static function newFactory()
    {
        return CounterFactory::new();
    }

    /**
     * Define the model's default state.
     *
     * @return array
     */
    public function definition()
    {
        return [
            'counter' => 1,
        ];
    }
}
