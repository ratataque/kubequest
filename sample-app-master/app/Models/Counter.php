<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;

/**
 * @method static int|float sum(string $column)
 */
class Counter extends Model
{
    use HasFactory;
}
