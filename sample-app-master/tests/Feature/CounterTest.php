<?php

namespace Tests\Feature;

use Tests\TestCase;

class CounterTest extends TestCase
{
    /**
     * A basic feature test example.
     *
     * @return void
     */
    public function getCounter()
    {
        $response = $this->get('/api/counter/count');

        $response->assertStatus(200);
    }

    /** @test */
    public function get_counter_value()
    {
        $response = $this->get('/api/counter/count');

        $response->assertJsonStructure(['value']);
    }

    /** @test */
    public function add_counter()
    {
        $response = $this->get('/api/counter/add');

        $response->assertStatus(200);
    }

    /** @test */
    public function add_counter_value()
    {
        $response = $this->get('/api/counter/add');

        $response->assertJsonStructure(['value']);
    }
}
