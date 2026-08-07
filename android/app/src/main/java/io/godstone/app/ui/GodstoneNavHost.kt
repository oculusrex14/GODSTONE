package io.godstone.app.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Home
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import io.godstone.app.ui.browse.BrowseScreen
import io.godstone.app.ui.home.HomeScreen

/** Production navigation exposes only repository-supported Archive behavior. */
sealed class Dest(val route: String, val label: String) {
    data object Home : Dest("home", "Home")
    data object Browse : Dest("browse", "Archive")
}

@Composable
fun GodstoneNavHost() {
    val nav = rememberNavController()
    val backStack by nav.currentBackStackEntryAsState()
    val current = backStack?.destination?.route
    val destinations = listOf(Dest.Home, Dest.Browse)

    Scaffold(bottomBar = {
        NavigationBar {
            destinations.forEach { dest ->
                NavigationBarItem(
                    selected = current == dest.route,
                    onClick = {
                        nav.navigate(dest.route) {
                            popUpTo(Dest.Home.route)
                            launchSingleTop = true
                        }
                    },
                    icon = {
                        Icon(
                            if (dest == Dest.Home) Icons.Filled.Home else Icons.Filled.Book,
                            contentDescription = dest.label
                        )
                    },
                    label = { Text(dest.label) }
                )
            }
        }
    }) { padding ->
        NavHost(
            navController = nav,
            startDestination = Dest.Home.route,
            modifier = androidx.compose.ui.Modifier.padding(padding)
        ) {
            composable(Dest.Home.route) { HomeScreen(onOpenArchive = { nav.navigate(Dest.Browse.route) }) }
            composable(Dest.Browse.route) { BrowseScreen() }
        }
    }
}
